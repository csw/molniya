## Molniya: an IM gateway for Nagios
##
## Dedicated to Sergey Korolev, the Chief Designer,
## and Boris Chertok, who wrote it all down for us.
##
## Copyright 2009 Windermere Services Company.
## By Clayton Wheeler, cswheeler@gmail.com
##
## This program is free software; you can redistribute it and/or modify
## it under the terms of the GNU General Public License as published by
## the Free Software Foundation; version 2 of the License.
##   
## This program is distributed in the hope that it will be useful,
## but WITHOUT ANY WARRANTY; without even the implied warranty of
## MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
## General Public License for more details.

require 'logger'
require 'net/smtp'
require 'optparse'
require 'ostruct'
require 'pathname'
require 'rexml/document'
require 'set'
require 'strscan'
require 'thread'
require 'time'
require 'timeout'
require 'uri'

require 'rack'
require 'sinatra/base'
require 'xmpp4r'
require 'xmpp4r/roster'
require 'xmpp4r/xhtml'
require 'yaml'

require 'inspectable'
require 'nagios'
require 'commands'
require 'formatting'

#### TODO
# rosters
# commands (down, ack, etc)
# proper service initialization / linking
# hosts in status
# consider filtering out stuff (sweeps et al) from status reports
# summarize dependencies
# broadcast
# dialogue

module Molniya

  SECOND = 1
  MINUTE = 60
  HOUR = 60 * MINUTE
  DAY = 24 * HOUR
  WEEK = 7 * DAY

  OLD = Time.parse('1996-01-01')

  TSPEC = [[WEEK, 'w'],
           [DAY, 'd'],
           [HOUR, 'h'],
           [MINUTE, 'm'],
           [SECOND, 's']]

  XMPP_AVAIL = [:chat, :available]

  LOG = Logger.new(STDERR)

  def self.brief_time_delta(t)
    if t > OLD
      Molniya::brief_duration((Time.now - t).to_i)
    else
      'ever'
    end
  end

  def self.brief_duration(secs, parts=TSPEC)
    if parts.empty?
      return ''
    else
      n, char = parts[0]
      if secs > n
        part = (secs / n).to_s + char
        return part + Molniya::brief_duration(secs % n, parts[1..1])
      else
        return Molniya::brief_duration(secs, parts[1..-1])
      end
    end
  end

  class Contact
    include Inspectable
    attr_accessor :jid, :roster_item, :missed, :recent, :seq
    inspect_my :jid

    def initialize(jid)
      @jid = jid
      @recent = {}
      @seq = 0
      @missed = []
    end

    def available?
      if ! roster_item
        LOG.warn "WARNING: no roster item for #{jid}: #{self.inspect}"
        return false
      end
      if roster_item.online?
        LOG.debug "last presences for #{jid}: #{roster_item.presences.last}, show #{roster_item.presences.last.show}"
        show = roster_item.presences.last.show || :available
        return XMPP_AVAIL.member?(show)
      else
        return false
      end
    end

    def record_notification(n)
      if seq < 9
        @seq = (@seq + 1)
      else
        @seq = 0
      end
      recent[seq] = n
      return seq
    end

    def to_s
      ""
    end

  end

  class TraceClient < Jabber::Client
    def send(xml, &block)
      $stderr.puts "XMPP: sending #{xml}"
      return super(xml, &block)
    end

    def receive(e)
      $stderr.puts "XMPP: received #{e}"
      return super(e)
    end
  end

  class XMPPClient
    include Inspectable
    attr_accessor :sb, :client, :roster, :contacts, :inbox, :worker, :disco
    attr_reader :command_defs
    inspect_my :client

    BASE_COMMAND_DEFS = [Commands::Status, Commands::Check, Commands::Ack,
                         Commands::Reply, Commands::Admin, Commands::Help]

    def initialize(sb)
      @sb = sb
      @contacts = {} # Hash.new {|h, jid| h[jid] = Contact.new(jid)}
      @inbox = Queue.new
      @client = Jabber::Client.new(sb.conf['username'])
      @command_defs = BASE_COMMAND_DEFS.clone
      if sb.options.eval
        command_defs << Commands::Eval
      end
      # @client = TraceClient.new(sb.conf['username'])
      client.on_exception do |e, client, where|
        LOG.error("Error connecting in #{where}: #{e}")
        LOG.error(e.backtrace.join("\n")) if e
      end
      LOG.info "Connecting to XMPP server..."
      connect()
      @roster = Jabber::Roster::Helper.new(client)
      init_callbacks()
      presence()
      @worker = nil
    end

    def start_worker()
      @worker = Thread.new { run() }
    end

    def connect()
      while true
        begin
          status = Timeout::timeout(15) do
            _connect()
          end
          ## success
          register_for_reconnect()
          break
        rescue StandardError => e
          LOG.error "Failed to connect: #{e}"
          begin
            client.close()
          rescue StandardError => ce
            LOG.error "Failed to close connection: #{ce}"
          end
          LOG.info "Sleeping 15 seconds before retry."
          sleep 15
        rescue Timeout::Error
          LOG.info "Timed out attempting to connect."
          begin
            client.close()
          rescue StandardError => ce
            LOG.error "Failed to close connection: #{ce}"
          end
        end
      end
    end

    def _connect()
      client.connect()
      LOG.info "Connected."
      client.auth(sb.conf['password'])
      LOG.debug "Authenticated."
    end

    def register_for_reconnect()
      client.on_exception do |e, client, where|
        LOG.warn("Reconnecting after exception in #{where}: #{e}")
        LOG.error(e.backtrace.join("\n")) if e
        reconnect()
      end
    end

    def reconnect()
      ## clear reconnect handler, we're already trying
      client.on_exception {}
      connect()
      presence()
      LOG.info "Successfully reconnected."
    end

    def enqueue_in(item)
      inbox << item
      #if not success
      #  log "inbox full, dropped #{item.inspect}"
      #end
    end

    def presence_sym(p)
      if p
        if p.type == :unavailable
          :unavailable
        else
          p.show || :available
        end
      else
        :unavailable
      end
    end

    def init_callbacks()
      ## client callbacks are invoked in parser thread, must enqueue
      client.add_message_callback { |msg| enqueue_in([:message, msg]) }

      ## roster callbacks are invoked in separate threads, just do stuff
      roster.add_presence_callback do |roster_item, old_pres, new_pres|
        old_p = presence_sym(old_pres)
        new_p = presence_sym(new_pres)
        jid = roster_item.jid.strip
        LOG.debug "got presence for #{jid}: old #{old_p}, new #{new_p}"
        unless contacts.has_key? jid
          c = Contact.new(jid)
          c.roster_item = roster_item
          contacts[jid.to_s] = c
        end
        if (! XMPP_AVAIL.member?(old_p)) \
          && XMPP_AVAIL.member?(new_p)
          # came online, catch up
          contact = contacts[jid]
          sb.catch_up(contact)
        end
      end
      # TODO: subscription stuff
    end

    ### handle incoming XMPP traffic

    def known_sender?(msg)
      # TODO
      return true
      addr = msg.from.strip
      unless contacts.has_key? addr
        LOG.warn "unknown sender: #{msg.from}"
        return false
      end
      unless sb.is_xmpp_contact?(addr)
        LOG.warn "not a Nagios contact: #{addr}"
        return false
      end
      return true
    end

    def handle_message(msg)
      ## TODO: down
      ## TODO: ls
      ## TODO: admin alias (?? what was this supposed to be?)
      unless msg.body
        LOG.debug "message with no body."
        return
      end
      unless known_sender? msg
        return
      end
      LOG.debug "message from #{msg.from.strip}: #{msg.body.inspect}"
      contact = contacts[msg.from.strip]
      scanner = StringScanner.new(msg.body)
      first = scanner.scan(/[^\s\/]+/)
      if not first
        LOG.warn "empty body? #{msg.body.inspect}"
        return
      end
      begin
        ## TODO: check contact can_submit_commands property on writes
        first_d = first.downcase
        cd = command_defs.find { |cd| cd.cmd === first_d }
        if cd
          LOG.debug "invoking command: #{cd}"
          invoke_cmd(cd, first_d, msg, contact, scanner)
        else
          # not a recognized command, is it host or host/svc?
          ## TODO: case-insensitive host search?
          host = sb.find_host(first)
          if host
            if scanner.scan(/\//)
              # host/svc
              svc = sb.resolve_service_name(host, scanner)
              invoke_cmd(Commands::ServiceDetail,
                         first, msg, contact, scanner, svc)
            else
              invoke_cmd(Commands::HostDetail,
                         first, msg, contact, scanner, host)
            end
          else
            LOG.debug "unhandled message: #{msg}"
            send_msg(msg.from,
                     "I\'m sorry, I didn\'t quite catch that?")
          end
        end
      rescue Exception => e
        LOG.error e
        LOG.error e.backtrace.join("\n")
        send_msg(msg.from, "Oops. #{e}")
        #raise
      end
    end

    def invoke_cmd(cmd_def, cmd_text, msg, contact, scanner, *rest)
      cmd = cmd_def.new
      cmd.cmd_text = cmd_text
      cmd.msg = msg
      cmd.contact = contact
      cmd.scanner = scanner
      cmd.sb = sb
      cmd.client = self
      cmd.invoke(*rest)
    end

    ### send messages

    def presence()
      if self.sb.status_msg != @last_presence
        client.send(Jabber::Presence.new(:chat, self.sb.status_msg))
        @last_presence = self.sb.status_msg
      end
    end

    def send_msg(jid, contents)
      LOG.debug "sending message to #{jid}: #{contents}"
      client.send(Jabber::Message.new(jid, contents))
    end

    def invite(jid)
      LOG.info "#{jid} is not on our list, asking..."
      @im.add(jid)
    end
    
    def send_if_online(jid, message)
      if @contacts.has_key? jid
        # existing contact
        if online?(jid)
          return send_msg(jid, message)
        else
          LOG.debug "#{jid} is #{status}, not sending"
          return false
        end
      else
        invite(jid)
        return false
      end
    end

    def online?(jid)
      @contacts[jid] == :online
    end

    def run()
      LOG.debug "Beginning XMPP message processing."
      keep_running = true
      while keep_running
        msg = nil
        begin
          item = inbox.pop()
          type = item[0]
          case type
          when :message
            msg = item[1]
            if msg.error
              case msg.error.type
              when :continue then LOG.warn "Server warning: #{msg.error}"
              when :cancel
                LOG.error "Unrecoverable error from XMPP server: #{msg.error}"
                client.close()
                keep_running = false
              else
                LOG.error "Unexpected error from XMPP server: #{msg.error}"
                keep_running = false
              end
            else
              if known_sender?(msg)
                #LOG.debug "received message: #{msg}"
                handle_message(msg)
              else
                LOG.warn "message from unknown sender: #{msg}"
              end
            end
          else
            LOG.error "unhandled inbox item: #{item.inspect}"
          end
        rescue Exception => e
          LOG.error e
          LOG.error e.backtrace.join("\n")
          if msg
            client.send_msg(msg.from, "Oops. #{e}")
          end
        end
      end
    end

  end

  class NagiosInstance
    include Inspectable
    ### thread-safe

    ## interesting commands
    # ACKNOWLEDGE_[HOST|SVC]_PROBLEM
    # ENABLE/DISABLE_ALL_NOTIFICATIONS_BEYOND_HOST
    # SAVE_STATE_INFORMATION
    # SCHEDULE_[HOST|SVC]_DOWNTIME
    # SCHEDULE_AND_PROPAGATE_HOST_DOWNTIME
    # SCHEDULE_HOSTGROUP_[HOST|SVC]_DOWNTIME
    # SCHEDULE_SERVICEGROUP_[HOST|SVC]_DOWNTIME
    # SEND_CUSTOM_[HOST|SVC]_NOTIFICATION

    ## TODO:
    # summarize dependencies in outages: 
    #   CRITICAL: host/some service and 8 dependent services

    attr_accessor :conf, :last, :last_mtime, :config, :status, :sb, :cmd_t

    def initialize(conf, sb)
      @conf = conf
      @last = nil
      @last_mtime = nil
      @sb = sb
      nagios_var = Pathname.new(conf['nagios_var'])
      nagios_cache = Pathname.new(conf['nagios_cache'] || conf['nagios_var'])
      @config = Nagios::Config.new(nagios_cache + 'objects.cache', self)
      @status = Nagios::Status.new(nagios_cache + 'status.dat', self)
      @cmd_t = Nagios::CommandTarget.new(nagios_var + 'rw' + 'nagios.cmd')
    end

    SVC_PROBLEMS = [:critical, :warning, :unknown]

    def status_exists?()
      status.source.exist?
    end
    
    def status_report()
      ok_hosts, bad_hosts =
        config.contents.hosts.values.partition { |h| h.cur_state == :ok }
      hosts = Set.new(bad_hosts)
      hosts_c = hosts.classify { |h| h.cur_state }
      problem_svcs = ok_hosts.collect do |h|
        h.services.values.find_all do |s|
          SVC_PROBLEMS.include? s.cur_state
        end
      end.flatten.to_set
      svcs_c = problem_svcs.classify { |s| s.cur_state }
      return {
        :hosts => hosts_c.to_a,
        :services => svcs_c.to_a
      }
    end

    def base_uri
      conf['nagios_uri']
    end

    def cgi(name)
      "#{base_uri}/cgi-bin/#{name}.cgi"
    end

    def status_uri(host)
      # http://nagios.example.com/nagios/cgi-bin/status.cgi?host=fran
      sprintf("%s?host=%s",
              cgi('status'),
              URI.encode(host))
    end

    def service_uri(host, svc)
      sprintf("%s?type=2&host=%s&service=%s",
              cgi('extinfo'),
              URI.encode(host),
              URI.encode(svc))
    end
  end

  class WebApp < Sinatra::Base
    include Inspectable

    set :environment, :production
    enable :dump_errors
    disable :show_exceptions

    post '/contact/:cname/notify' do
      #log "notification request with parameters: #{params.inspect}"
      settings.sb.notification(params[:cname], params['policy'], OpenStruct.new(params))
      status 204
    end
    
    post '/contact/:jid/send' do
      settings.sb.send_msg(params[:jid], params[:message] || params['rack.input'].read)
      status 204
    end
    
  end

  class Switchboard
    include Inspectable

    attr_accessor :conf, :nagios, :xmpp, :http, :fmt, :status_msg, :uri
    attr_accessor :options
    attr_reader :http_worker
    # :smtp, :http
    
    def initialize(options)
      @options = options
      conf = YAML::load(File.read(options.config))
      @conf = conf
      if conf.has_key? :log_config
        Molniya.const_set(:LOG, Logger.new(*conf[:log_config]))
      elsif conf.has_key? :log_file
        Molniya.const_set(:LOG, Logger.new(conf[:log_file], 'daily'))
      end
      LOG.level = case
                  when options.debug then Logger::DEBUG
                  when conf[:log_level] then Logger.const_get(conf[:log_level])
                  else Logger::INFO
                  end
      xmpp_fmt = case conf['xmpp_fmt'] || 'xhtml'
                 when 'xhtml' then XMPPHTMLFormatter.new(self)
                 when 'plain' then XMPPFormatter.new()
                 else raise "Unsupported formatting mode #{conf['xmpp_fmt']}"
                 end
      @nagios = NagiosInstance.new(conf, self)
      @fmt = {
        :xmpp => xmpp_fmt,
        :email => EmailFormatter.new,
        :email_subject => EmailSubjectFormatter.new
      }
      update_status_msg()
      LOG.debug "setting up XMPPClient"
      @xmpp = XMPPClient.new(self)
    end

    def start
      xmpp.start_worker()
      LOG.debug "Starting HTTP server with options: #{@conf['http_opts'].inspect}"
      WebApp.set(:sb, self)
      WebApp.set(:bind, @conf['http_opts'][:Host])
      WebApp.set(:port, @conf['http_opts'][:Port])
      @http_worker = Thread.new { WebApp.run! }
      until WebApp.running
        sleep 1
      end
    end

    def run
      interval = 30
      @int_trap_next = trap(:INT) do
        LOG.info "Interrupted, exiting."
        if @int_trap_next
          @int_trap_next.call()
        end
        xmpp.client.close
        exit 0
      end
      LOG.info "Switchboard running."
      while true
        unless xmpp.worker.alive?
          LOG.error "XMPPClient worker thread died!"
          xmpp.client.close
          LOG.info "Restarting XMPP subsystem..."
          @xmpp = XMPPClient.new(self)
          xmpp.start_worker()
          LOG.info "Restarted XMPP."
        end
        update_status_msg()
        if nagios.status.listeners?
          interval = 2
        else
          interval = 10
        end
        sleep(interval)
      end
    end

    def is_xmpp_contact?(addr)
      find_nagios_contact_with_jid(addr)
    end

    def find_nagios_contact_with_jid(addr)
      addr_s = addr.to_s
      field = conf['xmpp_field']
      contacts = nagios.config.contents.contacts
      return contacts.values.find { |c| c.props[field] == addr_s }
    end

    def find_host(name)
      return nagios.config.contents.hosts[name]
    end

    def find_service(hname, sname)
      h = find_host(hname)
      if h
        return h.services[sname]
      else
        return nil
      end
    end

    def find_notification_referent(n)
      case n.ntype
      when 'host'
        return find_host(n.HOSTNAME)
      when 'service'
        return find_service(n.HOSTNAME, n.SERVICEDESC)
      end
    end

    def resolve_service_name(host, scanner)
      s_names = host.services.keys.sort_by { |n| n.length }.reverse
      exact = s_names.find { |n| scanner.scan(Regexp.new(n, true)) }
      if exact
        return host.services[exact]
      else
        raise "Unknown service starting with #{scanner.rest} for host #{host.name}"
      end
    end

    def update_status_msg
      if nagios.status_exists?
        @status_msg = fmt[:xmpp].status_message(nagios.status_report())
      else
        LOG.warn "Nagios is not running!"
        @status_msg = "Nagios is not running!"
      end
      if xmpp
        xmpp.presence()
      end
    end

    def register_for_notification(item, contact)
      req_t = Time.now
      nagios.status.register do |sv|
        if item.last_check > req_t
          ## got an update, report on it
          xmpp.send_msg(contact.jid, item.detail(:xmpp))
          ## deregister
          false
        else
          ## no update yet, stay registered
          true
        end
      end
    end

    def check(item, notify=nil)
      req_t = Time.now
      ## force a check
      item.force_check(req_t)
      ## register if needed
      if notify
        register_for_notification(item, notify)
      end
    end

    def notification(contact_name, policy_spec, n)
      contacts = nagios.config.contents.contacts
      contact = contacts.fetch(contact_name)
      n.referent = find_notification_referent(n)
      unless n.referent
        raise "Couldn't find what notification referred to: #{n.inspect}"
      end
      policy_spec.split(';').each do |policy|
        case policy
        when 'xmpp'
          if xmpp_notification(contact, n)
            break
          end
        when 'email'
          email_notification(contact, contact.props.fetch('email'), n)
          break
        when 'pager'
          email_notification(contact, contact.props.fetch('pager'), n)
          break
        else
          raise "unknown policy #{policy} for #{contact}!"
        end
      end
    end

    def xmpp_notification(contact, n)
      jid = contact.props[conf['xmpp_field']]
      unless jid
        raise "Contact #{contact.name} does not have a JID in #{conf['xmpp_field']}: props #{contact.props.inspect}"
      end
      x_contact = xmpp.contacts[jid]
      unless x_contact
        LOG.warn "no contact with jid #{jid}, not sending message"
        return false
      end
      if x_contact.available?
        n.seq = x_contact.record_notification(n)
        xmpp.send_msg(jid, fmt[:xmpp].notification(n))
        return true
      else
        x_contact.missed << n
        return false
      end
    end

    def catch_up(contact)
      ## just came online
      LOG.debug "Catching up with contact #{contact.jid}."
      if not contact.missed.empty?
        LOG.debug "Has #{contact.missed.length} missed notifications"
        ## TODO: filter just for problem notifications?
        m_bad = contact.missed.collect { |n| find_notification_referent(n) } \
          .reject { |ref| ! ref } \
          .reject { |ref| ref.hard_state == :ok } \
          .to_set \
          .classify { |ref| ref.class }
        m_hosts = m_bad[Nagios::Host] || []
        m_svcs = m_bad[Nagios::Service] || []
        if (not m_hosts.empty?) || (not m_svcs.empty?)
          LOG.debug "Had problem notifications for existing problems."
          ## TODO: use a proper formatting mechanism
          msg = "While you were out:\n"
          if not m_hosts.empty?
            hmsg = m_hosts.classify { |h| h.hard_state }.collect do |state, hosts|
              sprintf("%s: %s", state.to_s.upcase,
                      hosts.sort.collect { |h| h.name }.join(", "))
            end.join("; ")
            msg << hmsg << "\n"
          end
          if not m_svcs.empty?
            smsg = m_svcs.classify { |s| s.hard_state }.collect do |state, svcs|
              sprintf("%s: %s", state.to_s.upcase,
                      svcs.sort.collect { |s| "#{s.host.name}/#{s.name}" }.join(", "))
            end.join("; ")
            msg << smsg << "\n"
          end
          LOG.debug "Sending message: #{msg}"
          send_msg(contact.jid, msg)
        end
        contact.missed.clear
      end
    end
    
    def send_msg(jid, msg)
      LOG.debug "Sending message to #{jid}: #{msg}"
      xmpp.send_msg(jid, msg)
    end

    def email_notification(contact, to, n)
      from = conf.fetch('smtp_from')
      subject = fmt[:email_subject].notification(n)
      body = fmt[:email].notification(n)
      message = <<EOF
From: Nagios <#{from}>
To: #{contact.props.fetch('alias')} <#{to}>
Date: #{Time.now.rfc822}
Subject: #{subject}

#{body}
EOF
      with_smtp_conn do |conn|
        conn.send_message(message, from, to)
        LOG.info "Sent notification to #{to} via SMTP."
      end
    end

    def with_smtp_conn
      Net::SMTP.start(conf['smtp_relay'], 25) do |smtp|
        yield smtp
      end
    end
    
  end

  def self.launch
    options = OpenStruct.new
    options.eval = false
    options.debug = false
    opt_p = OptionParser.new do |opts|
      opts.banner = "Usage: molniya [options]"
      opts.separator "Required options:"
      opts.on("-c", "--config FILE", "Configuration file") do |config|
        options.config = config
      end
      opts.separator "Optional:"
      opts.on("-e", "--[no-]eval", "Enable 'eval' command") do |e|
        options.eval = e
      end
      opts.on("-d", "--debug", "Debug mode") do
        options.debug = true
      end
      opts.on_tail("-h", "--help", "Show this message") do
        puts opts
        exit 1
      end
    end
    opt_p.parse!
    unless options.config
      puts opt_p
      exit 1
    end
    sb = Switchboard.new(options)
    sb.start
    sb.run
  end
end

