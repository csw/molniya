## commands.rb: Molniya commands
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

require 'metaid'

module Molniya
  module Commands
    class Base
      attr_accessor :cmd_text, :msg, :contact, :scanner, :sb, :client, :parent

      def self.cmd(word)
        meta_def(:cmd) { word }
      end

      def invoke_child(klass, c_cmd_text)
        c = klass.new
        c.cmd_text = c_cmd_text
        c.msg = msg
        c.contact = contact
        c.scanner = scanner
        c.sb = sb
        c.client = client
        c.parent = parent
        c.invoke
      end
    end

    class Status < Base
      cmd 'status'
      def invoke
        client.send_msg(msg.from, sb.status_report())
      end
    end

    class HostDetail < Base
      def invoke(host)
        client.send_msg(msg.from, host.detail(:xmpp))
      end
    end

    class ServiceDetail < Base
      def invoke(svc)
        client.send_msg(msg.from, svc.detail(:xmpp))
      end
    end

    class Check < Base
      cmd 'check'
      def invoke
        scanner.skip(/\s*/) or raise 'syntax'
        case
        when scanner.scan(/(\w+)\//)
          # host/svc
          host = sb.find_host(scanner[1]) or raise "Unknown host #{scanner[1]}"
          svc = sb.resolve_service_name(host, scanner)
          sb.check(svc, contact)
        when scanner.scan(/(\w+)/)
          # host
          host = sb.find_host(scanner[1]) or raise "Unknown host #{scanner[1]}"
          sb.check(host, contact)
        else
          raise 'syntax'
        end
      end
    end

    class ReplyAck < Base
      cmd 'ack'

      def invoke
        n_contact = sb.find_nagios_contact_with_jid(contact.jid)
        raise "No Nagios contact with JID #{contact.jid}?" unless n_contact
        scanner.skip(/\s*/)
        if scanner.scan_until(/\S.+/)
          comment = scanner.matched
        else
          comment = "acknowledged."
        end
        parent.n.referent.acknowledge(:author => n_contact.name,
                                      :comment => comment)
      end
    end

    class ReplyCheck < Base
      cmd 'check'

      def invoke
        sb.check(parent.n.referent, contact)
      end
    end

    class Reply < Base
      attr_accessor :n
      cmd /^@(\d)/

      SUB = [ReplyAck, ReplyCheck]

      def invoke
        unless cmd_text =~ cmd
          raise "inconsistent dispatch!"
        end
        n = contact.recent[$1.to_i]
        if n
          scanner.skip(/\s*/)
          scmd_w = scanner.scan(/\w+/) or raise "Missing subcommand!"
          scmd_def = SUB.find { |sd| sd.cmd === scmd_w }
          if scmd_def
            invoke_child(scmd_def, scmd_w)
          else
            client.send_msg(msg.from, "Unknown reply command #{scmd_w}!")
          end
        else
          client.send_msg(msg.from, "No record of notification #{$1}, sorry.")
          LOG.debug "Recent: #{contact.recent.inspect}"
        end        
      end
    end

    class Admin < Base
      cmd "admin"

      def invoke
        scanner.skip(/\s*/) or raise 'syntax'
        admin_cmd = scanner.scan(/\S+/)
        scanner.skip(/\s*/)
        case admin_cmd
        when 'list-roster'
          send(msg.from, "Roster: " + roster.items.keys.sort.join(", "))
        when 'add'
          if scanner.scan(/(\S+)\s+(\S+)/)
            jid = scanner[0]
            iname = scanner[1]
            roster.add(Jabber::JID.new(jid), iname, true)
            send(msg.from, "Added #{jid} (#{iname}) to roster and requested presence subscription.")
          else
            send(msg.from, "Usage: admin add <jid> <alias>")
          end
        when 'remove'
          jid = scanner.scan(/\S+/)
          if jid
            roster[jid].remove()
            send(msg.from, "Contact #{jid} successfully removed from roster.")
          else
            send(msg.from, "Usage: admin remove <jid>")
          end
        else
          send(msg.from, "Unknown admin command #{admin_cmd}")
        end
      end
    end

    class Eval < Base
      cmd "eval"

      def invoke
        ## TODO: conditionalize for debugging
        scanner.skip(/\s*/)
        send(msg.from, eval(scanner.rest()).inspect)
      end
    end

    class Help < Base
      cmd "help"

      def invoke
        send(msg.from, <<EOF)
Nagios switchboard commands:
status: get a status report
check <host | host/svc>: force a check of the named host or service
You can respond to a notification with its @ number, like so:
@N ack [message]: acknowledge a host or service problem, with optional message
@N check: force a check of the host or service referred to
EOF
      end
    end

  end
end