##
# This module requires Metasploit: http://metasploit.com/download
# Current source: https://github.com/rapid7/metasploit-framework
##

require 'msf/core'
require 'rex'


class MetasploitModule < Msf::Post


  def initialize(info={})
    super( update_info( info,
        'Name'          => 'Windows Manage Network Route via Meterpreter Session',
        'Description'   => %q{This module manages session routing via an existing
          Meterpreter session. It enables other modules to 'pivot' through a
          compromised host when connecting to the named NETWORK and SUBMASK.
          Autoadd will search session for valid subnets and route to them.},
        'License'       => MSF_LICENSE,
        'Author'        => [ 'todb'],
        'Platform'      => [ 'win' ],
        'SessionTypes'  => [ 'meterpreter']
      ))

    register_options(
      [
        OptString.new('SUBNET', [false, 'Subnet (IPv4, for example, 10.10.10.0)', nil]),
        OptString.new('NETMASK', [false, 'Netmask (IPv4 as "255.255.255.0" or CIDR as "/24"', '255.255.255.0']),
        OptEnum.new('CMD', [true, 'Specify the autoroute command', 'autoadd', ['add','autoadd','print','delete']])
      ], self.class)
  end

  # Backwards compatability: This was changed because the option name of "ACTION"
  # is special for some things, and indicates the :action attribute, not a datastore option.
  # However, this is a semi-popular module, though, so I'd prefer not to break people's
  # RC scripts that set ACTION. Note that ACTION is preferred over CMD.
  #
  # TODO: The better solution is to use 'Action' and 'DefaultAction' info elements,
  # but there are some squirelly problems right now with rendering these for post modules.
  def route_cmd
    if datastore['ACTION'].to_s.empty?
      datastore['CMD'].to_s.downcase.to_sym
    else
      wlog("Warning, deprecated use of 'ACTION' datastore option for #{self.fullname}'. Use 'CMD' instead.")
      datastore['ACTION'].to_s.downcase.to_sym
    end
  end

  # Run Method for when run command is issued
  def run
    print_status("Running module against #{sysinfo['Computer']}")

    case route_cmd()
    when :print
      print_routes()
    when :add
      if validate_cmd(datastore['SUBNET'],netmask)
        print_status("Adding a route to %s/%s..." % [datastore['SUBNET'],netmask])
        add_route(:subnet => datastore['SUBNET'], :netmask => netmask)
      end
    when :autoadd
      autoadd_routes
    when :delete
      if datastore['SUBNET']
        print_status("Deleting route to %s/%s..." % [datastore['SUBNET'],netmask])
        delete_route(:subnet => datastore['SUBNET'], :netmask => netmask)
      else
        delete_all_routes()
      end
    end
  end

  def delete_all_routes
    if Rex::Socket::SwitchBoard.routes.size > 0
      routes = []
      Rex::Socket::SwitchBoard.each do |route|
        routes << {:subnet => route.subnet, :netmask => route.netmask}
      end
      routes.each {|route_opts| delete_route(route_opts)}

      print_status "Deleted all routes"
    else
      print_status "No routes have been added yet"
    end
  end

  # Identical functionality to command_dispatcher/core.rb, and
  # nearly identical code
  def print_routes
    if Rex::Socket::SwitchBoard.routes.size > 0
      tbl =	Msf::Ui::Console::Table.new(
        Msf::Ui::Console::Table::Style::Default,
        'Header'  => "Active Routing Table",
        'Prefix'  => "\n",
        'Postfix' => "\n",
        'Columns' => [
          'Subnet',
          'Netmask',
          'Gateway',
        ],
        'ColProps' => {
          'Subnet'  => { 'MaxWidth' => 17 },
          'Netmask' => { 'MaxWidth' => 17 },
        })
      ret = []

      Rex::Socket::SwitchBoard.each { |route|
        if (route.comm.kind_of?(Msf::Session))
          gw = "Session #{route.comm.sid}"
        else
          gw = route.comm.name.split(/::/)[-1]
        end
        tbl << [ route.subnet, route.netmask, gw ]
      }
      print_line tbl.to_s
    else
      print_status "No routes have been added yet"
    end
  end

  # Yet another IP validator. I'm sure there's some Rex
  # function that can just do this.
  def check_ip(ip=nil)
    return false if(ip.nil? || ip.strip.empty?)
    begin
      rw = Rex::Socket::RangeWalker.new(ip.strip)
      (rw.valid? && rw.length == 1) ? true : false
    rescue
      false
    end
  end

  def cidr_to_netmask(cidr)
    int = cidr.gsub(/\x2f/,"").to_i
    Rex::Socket.addr_ctoa(int)
  end

  def netmask
    case datastore['NETMASK']
    when /^\x2f[0-9]{1,2}/
      cidr_to_netmask(datastore['NETMASK'])
    when /^[0-9]{1,3}\.[0-9]/ # Close enough, if it's wrong it'll fail out later.
      datastore['NETMASK']
    else
      "255.255.255.0"
    end
  end

  # Adds a route to the framework instance
  def add_route(opts={})
    subnet = opts[:subnet]
    Rex::Socket::SwitchBoard.add_route(subnet, netmask, session)
  end

  # Removes a route to the framework instance
  def delete_route(opts={})
    subnet = opts[:subnet]
    Rex::Socket::SwitchBoard.remove_route(subnet, netmask, session)
  end

  # This function will check if a subnet/netmask pair is routable
  #
  # @return [true]  if routable
  # @return [false] if not
  def is_routable?(subnet, netmask)
    if subnet =~ /^224\.|127\./
      return false
    elsif subnet == '0.0.0.0'
      return false
    elsif netmask == '255.255.255.255'
      return false
    end

    return true
  end

  # This function will search for valid subnets on the target and attempt
  # add a route to each. (Operation from auto_add_route plugin.)
  #
  # @return [void] A useful return value is not expected here
  def autoadd_routes
    switch_board = Rex::Socket::SwitchBoard.instance
    print_status("Searching for subnets to autoroute.")
    found = false

    session.net.config.each_route do | route |
      next unless is_routable?(route.subnet, route.netmask)

      if !switch_board.route_exists?(route.subnet, route.netmask)
        begin
          if Rex::Socket::SwitchBoard.add_route(route.subnet, netmask, session)
            print_good("Route added to subnet #{route.subnet}/#{route.netmask}")
            found = true
          else
            print_error("Could not add route to subnet #{route.subnet}/#{route.netmask}")
          end
        rescue ::Rex::Post::Meterpreter::RequestError => error
          print_error("Could not add route to subnet #{route.subnet}/(#{route.netmask})")
          print_error(error.to_s)
        end
      end
    end
    autoadd_interface_routes
    print_status("Did not find any new subnets to add.") if !found
  end

  # This function will look at network interfaces as options for additional routes.
  # If the routes are not already included they will be added.
  #
  # @return [void] A useful return value is not expected here
  def autoadd_interface_routes
    session.net.config.each_interface do | interface |

      (0..(interface.addrs.size - 1)).each do | index |

        ip_addr = interface.addrs[index]
        netmask = interface.netmasks[index]

        next unless ip_addr =~ /\./
        next unless is_routable?(ip_addr, netmask)

        print_status("Interface: #{interface.mac_name}  =  #{ip_addr} : #{netmask}")
        get_subnet(ip_addr, netmask)

      end
    end
  end

  # This function will take an IP address and a netmask and return
  # the appropreate subnet "Network"
  #
  # @ip_addr [string class] Input IPv4 Address
  # @netmask [string class] Input IPv4 Netmask
  #
  # @return [nil class] Something is out of range
  # @return [string class] The subnet related to the IP address and netmask
  def get_subnet(ip_addr, netmask)
    return nil if !validate_cmd(ip_addr, netmask)

    nets = ip_addr.split('.')
    masks = netmask.split('.')

    (0..3).each do | index |
      get_subnet_octet(int_or_nil(nets[index]), int_or_nil(masks[index]))
    end
  end

  # This function an octet of an IPv4 address and the cooresponding octet of the
  # IPv4 netmask and returns the appropreate subnet octet.
  #
  # @net  [integer class] IPv4 address octet
  # @mask [integer class] Ipv4 netmask octet
  #
  # @return [integer class] Integer representation of the number string
  # @return [nil class] string contains non-numbers, cannot convert
  def get_subnet_octet(net, mask)
    subnet_range = 256 - mask  #This is the address space of the coorisponding subnet octet

    multi = net / subnet_range #Integer division to get the multiplier needed to deturmine subnet octet

    octet = subnet_range * multi
    print_status("\tSubnet_Range: #{subnet_range}    Multi: #{multi}   Octet:#{octet}")
  end

  # This function takes a string of numbers and converts it to an integer.
  #
  # @string [string class] Input string, needs to be all numbers (0..9)
  # @return [integer class] Integer representation of the number string
  # @return [nil class] string contains non-numbers, cannot convert
  def int_or_nil(string)
    num = string.to_i
    num if num.to_s == string
  end

  # Validates the command options
  def validate_cmd(subnet=nil,netmask=nil)
    if subnet.nil?
      print_error "Missing subnet option"
      return false
    end

    unless(check_ip(subnet))
      print_error "Subnet invalid (must be IPv4)"
      return false
    end

    if(netmask and !(Rex::Socket.addr_atoc(netmask)))
      print_error "Netmask invalid (must define contiguous IP addressing)"
      return false
    end

    if(netmask and !check_ip(netmask))
      print_error "Netmask invalid"
      return false
    end
    true
  end
end
