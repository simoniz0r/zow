#!/usr/bin/tclsh
# Name: zow
# Author: Syretia
# License: MIT
# Description: zypper OBS wrapper that adds OBS package search and install
# Dependencies: tcllib, tdom, tls

package require rest
package require tls
package require cmdline

# setup https
http::register https 443 [list ::tls::socket -autoservername true]

# set version
set version "0.2.05"

# proc that uses ANSI escapes to set colors
proc color {foreground text} {
    return "\033\[${foreground}m$text\033\[0m"
}

# proc that parses named colors into ANSI escape codes
proc color_parse {color} {
    switch -exact $color {
        red {return 31}
        green {return 32}
        brown -
        yellow {return 33}
        blue {return 34}
        purple -
        magenta {return 35}
        cyan {return 36}
        gray {return 38}
        bold {return 1}
        white -
        default {return 37}
    }
}

# proc that gets color config
proc color_config {path} {
    # set necessary vars as global
    global msgError msgWarning highlight positive change prompt
    # set default colors
    set msgError 37
    set msgWarning 37
    set highlight 37
    set positive 37
    set change 37
    set prompt 37
    # catch error when opening
    if {[catch {open $path}] == 0} {
        # open and read config file
        set fileID [open $path]
        set file [read $fileID]
        # get useColors config option from file
        set useColors [lindex [split [lindex [regexp -inline -line -- {useColors\s=\s\w+} $file] 0] { }] 2]
        # if not found, set to false
        if {$useColors == {}} {
            set useColors false
        }
        if {$useColors != "false"} {
            # get colors from config file if useColors is not false
            set msgError [color_parse [lindex [split [lindex [regexp -inline -line -- {msgError\s=\s\w+} $file] 0] { }] 2]]
            set msgWarning [color_parse [lindex [split [lindex [regexp -inline -line -- {msgWarning\s=\s\w+} $file] 0] { }] 2]]
            set highlight [color_parse [lindex [split [lindex [regexp -inline -line -- {highlight\s=\s\w+} $file] 0] { }] 2]]
            set positive [color_parse [lindex [split [lindex [regexp -inline -line -- {positive\s=\s\w+} $file] 0] { }] 2]]
            set change [color_parse [lindex [split [lindex [regexp -inline -line -- {change\s=\s\w+} $file] 0] { }] 2]]
            set prompt [color_parse [lindex [split [lindex [regexp -inline -line -- {prompt\s=\s\w+} $file] 0] { }] 2]]
        }
    }
}

# proc that separates short flags so cmdline can parse them
proc flag_separator {arguments} {
    # create args variable
    set args {}
    # loop on arguments
    foreach arg $arguments {
        # if arg does not start with -- and does start with -
        if {[string first {--} $arg] != 0 && [string first {-} $arg] == 0} {
            # loop on each character in arg split into list
            foreach flag [lrange [split $arg {}] 1 end] {
                # insert flag with - into args list
                set args [linsert $args end "-$flag"]
            }
        } else {
            # else just insert arg into args list
            set args [linsert $args end $arg]
        }
    }
    return $args
}

# proc that runs commands and captures stdout
proc exec_cap {command} {
    # set necessary vars as global
    global exitcode stderr stdout
    # set default values
    set exitcode 0
    set stderr {}
    set stdout {}
    # run command and catch any non-zero exit
    if {[catch {exec -keepnewline -- {*}$command} output options] != 0} {
        # get errorcode from options dict
        set errorcode [dict get $options -errorcode]
        # if first entry in errorcode is CHILDSTATUS set exitcode to third entry
        if {[lindex $errorcode 0] == "CHILDSTATUS"} {
            set exitcode [lindex $errorcode 2]
        }
        # stderr is last line of output
        set stderr [lindex [split $output "\n"] end]
        # stdout is all lines except last of output
        set stdout [join [lrange [split $output "\n"] 0 end-1] "\n"]
    } else {
        # stdout is output
        set stdout $output
    }
}

# proc that runs commands and sends stdout directly to terminal instead of capturing it
proc exec_nocap {command} {
    # set necessary vars as global
    global exitcode stderr
    # set default values
    set exitcode 0
    set stderr {}
    chan configure stdout -buffering none
    # run command and catch any non-zero exit
    if {[catch {exec -keepnewline -- >@stdout {*}$command} output options] != 0} {
        # get errorcode from options dict
        set errorcode [dict get $options -errorcode]
        # if first entry in errorcode is CHILDSTATUS set exitcode to third entry
        if {[lindex $errorcode 0] == "CHILDSTATUS"} {
            set exitcode [lindex $errorcode 2]
        }
        # stderr is output
        set stderr $output
    }
}

# proc that handles all generic zypper calls
proc zypper {arguments} {
    # set necessary vars as global
    global exitcode stderr
    # run zypper through exec_nocap proc
    exec_nocap "zypper $arguments"
    # re-run zypper with sudo if exit is 5
    if {$exitcode == 5} {
        exec_nocap "sudo zypper $arguments"
    }
    # ouput stderr if exit code is not 0
    if {$exitcode != 0 && $stderr != "child process exited abnormally"} {
        puts stderr $stderr
    }
}

# proc that decides which searches to run
proc zypper_search {repos packages} {
    # get colors for output
    color_config {/etc/zypp/zypper.conf}
    switch -exact -- $repos {
        all { ;# both local and OBS repos
            zypper_search_local "$packages"
            zypper_search_obs "search" "$packages"
        }
        obs { ;# only OBS repos
            zypper_search_obs "search" "$packages"
        }
        local { ;# only local repos
            zypper_search_local "$packages"
        }
    }
}

# proc that handles package search through zypper
proc zypper_search_local {arguments} {
    # set necessary vars as global
    global stdout exitcode msgError msgWarning highlight positive change prompt
    # run zypper search
    exec_cap "zypper --no-refresh --xmlout search $arguments"
    # trim xml just in case
    set zypper_results [string trim $stdout]
    # use tdom to parse xml
    set xml [rest::format_tdom $zypper_results]
    # get messages from xml
    set msgs [$xml selectNodes {/stream/message/text()}]
    # output messages
    foreach msg $msgs {
        puts [$msg nodeValue]
    }
    # blank line
    puts {}
    # get search results from xml
    set results [$xml selectNodes {/stream/search-result/solvable-list/solvable}]
    # output search results
    foreach result $results {
        # set colors based on status attribute
        if {[$result getAttribute status] == "installed"} {
            set nameColor $positive
            set statusColor $positive
        } elseif {[$result getAttribute status] == "other-version"} {
            set nameColor $highlight
            set statusColor $msgWarning
        } else {
            set nameColor $highlight
            set statusColor 8
        }
        # output result, formatting depends on if summary attribute exists in result
        if {[catch {$result getAttribute summary}] == 0} {
            puts "[color $prompt [color $nameColor [$result getAttribute name]]] |\
            [$result getAttribute kind] |\
            [color $statusColor [$result getAttribute status]]"
            puts "    [$result getAttribute summary]\n"
        } else {
            puts "[color $prompt [color $nameColor [$result getAttribute name]]] |\
            [color $change [$result getAttribute repository]] |\
            [$result getAttribute edition] |\
            [$result getAttribute arch] |\
            [$result getAttribute kind] |\
            [color $statusColor [$result getAttribute status]]\n"
        }
    }
}

# proc that handles searching OBS repos
proc zypper_search_obs {type arguments} {
    # set necessary vars as global
    global exitcode msgError msgWarning highlight positive change prompt
    # separate any short flags in arguments so cmdline can parse them
    set args [flag_separator "$arguments"]
    # create flags and usage for cmdline
    set flags {
        {s           "detailed output"}
        {details     "detailed output"}
        {x           "exact match"}
        {match-exact "exact match"}
    }
    set usage {}
    # parse flags using cmdline::getKnownOptions
    set flags_parsed [cmdline::getKnownOptions args $flags $usage]
    # check if --details or -s used
    if {[dict get $flags_parsed details] == 1} {
        set detailed [dict get $flags_parsed details]
    } else {
        set detailed [dict get $flags_parsed s]
    }
    #check if --match-exact or -x used
    if {[dict get $flags_parsed match-exact] == 1} {
        set exact [dict get $flags_parsed match-exact]
    } else {
        set exact [dict get $flags_parsed x]
    }
    # create packages variable
    set packages {}
    # loop through args and add anything that doesn't start with - to packages list
    foreach arg $args {
        if {[string first {-} $arg] != 0} {
            set packages [linsert $packages end $arg]
        }
    }
    # get openSUSE version from /etc/products.d/baseproduct
    if {[catch {set baseproduct_id [open /etc/products.d/baseproduct]}] != 0} {
        puts stderr [color $msgError "Error opening {/etc/products.d/baseproduct}"]
        exit 1
    }
    set baseproduct [rest::format_tdom [read $baseproduct_id]]
    set release [regsub -all {\s} [$baseproduct selectNodes {string(/product/summary)}] {%253A}]
    # set URL to opi proxy
    set opi_proxy {https://opi-proxy.opensuse.org/?obs_api_link=}
    # output heading if $type is search
    puts "[color $prompt [color $msgWarning "Searching OBS repos..."]]"
    # loop through $packages
    foreach package $packages {
        # set query based on if -x or --match-exact flag used
        if {$type == "install" || $exact == 1} {
            set query "%2540name%253D%2527$package%2527"
        } else {
            set query "contains-ic%2528%2540name%252C%2B%2527$package%2527%2529"
        }
        # set obs_api_link containing $query and $release
        set obs_api_link "https%3A%2F%2Fapi.opensuse.org%2Fsearch%2Fpublished%2Fbinary%2Fid%3Fmatch%3D$query%2Band%2Bpath%252Fproject%253D%2527$release%2527%26limit%3D0&obs_instance=openSUSE"
        # set full_url to contain $opi_proxy and $obs_api_link
        set full_url "$opi_proxy$obs_api_link"
        # use rest to get results from $full_url
        if {[catch {set obs_results [rest::get $full_url {}]}] != 0} {
            # failed to get results from API, exit
            puts stderr [color $msgError "Failed to get search results from $full_url."]
            exit 1
        }
        # use tdom to parse xml
        set xml [rest::format_tdom $obs_results]
        # check how many matches
        set collection [$xml selectNodes {/collection}]
        set matches [$collection getAttribute {matches}]
        if {$matches == 0} {
            if {$type == "install"} {
                puts stderr [color $msgError "No provider of '$package' found."]
                exit 104
            } else {
                puts {No matching items found.}
                exit 104
            }
        }
        set exitcode 0
        # get machine architecture
        set system_arch [exec uname -m]
        # get list of binary results from xml
        set raw_binary_list [$xml selectNodes {/collection/binary}]
        # create binary_list
        set binary_list {}
        # filter irrelevant architectures out of raw_binary_list
        foreach raw_binary $raw_binary_list {
            set raw_arch [$raw_binary getAttribute arch]
            if {$raw_arch == "noarch" || $raw_arch == $system_arch} {
                set binary_list [linsert $binary_list end $raw_binary]
            }
        }
        # output results based on $type
        puts "OBS search results:\n"
        if {$type != "search"} {
            return $binary_list
        } else {
            foreach binary $binary_list {
                puts "[color $prompt [color $highlight [$binary getAttribute name]]] |\
                [color $change [$binary getAttribute project]] |\
                [$binary getAttribute version]-[$binary getAttribute release] |\
                [$binary getAttribute arch]"
                # only output OBS project link if $detailed is not 1
                if {$detailed == 1} {
                    puts {}
                } else {
                    puts "    https://build.opensuse.org/project/show/[$binary getAttribute project]\n"
                }
            }
        }
    }
}

# proc that decides which repos to install from
proc zypper_install {repos packages} {
    # get colors for output
    color_config {/etc/zypp/zypper.conf}
    switch -exact -- $repos {
        all { ;# both local and OBS repos
            zypper "install [join $packages " "]"
            if {$exitcode == 104} {
                zypper_install_obs "$packages"
            }
        }
        obs { ;# only OBS repos
            zypper_install_obs "$packages"
        }
        local { ;# only local repos
            zypper "install [join $packages " "]"
        }
    }
}

# proc to install packages from OBS repos
proc zypper_install_obs {packages} {
    # set necessary vars as global
    global exitcode msgError msgWarning highlight positive change prompt
    # loop through $packages
    foreach package $packages {
        set binary_list [zypper_search_obs "install" "$package"]
        # loop through results
        set opt_num 0
        set list_length [llength $binary_list]
        incr list_length -1
        foreach binary $binary_list {
            incr opt_num
            # set padding
            if {$opt_num < 10 && $list_length > 8} {
                set bin_num " $opt_num"
            } else {
                set bin_num $opt_num
            }
            # output each result
            puts "$bin_num) [color $change [$binary getAttribute project]] |\
            [$binary getAttribute version]-[$binary getAttribute release]"
        }
        # add cancel option
        if {$list_length > 8} {
            puts " C) Cancel\n"    
        } else {
            puts "C) Cancel\n"
        }
        # output prompt and wait for input
        puts -nonewline "[color $prompt "Choose an OBS repo to install '[color $highlight $package]"][color $prompt {' from and press ENTER:}] "
        flush stdout
        gets stdin input
        # check input
        if {[catch {incr input -1} iner] != 0 || $input > $list_length || $input < 0} {
            puts "Invalid choice.  Nothing to do."
            exit 4
        }
        # add repo and install package
        set result [lindex $binary_list $input]
        set repo [$result getAttribute project]
        set repo_alias [regsub -all {:} $repo {_}]
        zypper "ar -f -p 100 obs://$repo $repo_alias"
        if {$exitcode != 0} {
            exit $exitcode
        }
        zypper "ref"
        if {$exitcode != 0} {
            exit $exitcode
        }
        zypper "install --from $repo_alias $package"
    }
}

# proc to output help
proc zow_help {arguments} {
    # set necessary vars as global
    global exitcode stderr stdout
    if {$arguments == ""} {
        # add zow's help to zypper's help output if no arguments
        exec_cap "zypper help"
        # replace 'zypper' with 'zow'
        set stdout [regsub -all {zypper } $stdout {zow }]
        # replace 'Install packages.' with a '#' for easier splitting
        set stdout [regsub {Install packages\.} $stdout {#}]
        # replace 'Search...' with a '#' and split by '#'
        set help_list [split [regsub {Search for packages matching a pattern\.} $stdout {#}] {#}]
        # add zow's help to each split section
        puts "[lindex $help_list 0]Install packages from local repos or OBS repos if not available in local."
        puts "      local-install, lin    Install packages from local repos only."
        puts -nonewline "      obs-install, oin      Install packages from OBS repos only."
        puts "[lindex $help_list 1]Search for packages matching a pattern in local and OBS repos."
        puts "      local-search, lse     Search for packages matching a pattern in local repos only."
        puts "      obs-search, ose       Search for packages matching a pattern in OBS repos only."
        puts "      changes, ch           Show RPM changes file for a package."
        puts -nonewline "      list-files, lf        List installed files for a package."
        puts [lindex $help_list 2]
    } else {
        # if arguments pass them along with 'help' to zypper proc
        # TODO add specific help outputs for zow's arguments
        zypper "help $arguments"
    }
}


# detect input
switch -exact -- [lindex $argv 0] {
    ch -
    changes { ;# use rpm to show changes file
        exec_nocap "rpm -q --changes [lrange $argv 1 end]"
        if {$exitcode != 0} {
            puts stderr $stderr
        }
    }
    lf -
    list-files { ;# use rpm to list files in package
        exec_nocap "rpm -q --filesbypkg [lrange $argv 1 end]"
        if {$exitcode != 0} {
            puts stderr $stderr
        }
    }
    lse -
    local-search { ;# package search from local repos only
        zypper_search "local" "[lrange $argv 1 end]"
    }
    ose -
    obs-search { ;# package search from OBS repos only
        zypper_search "obs" "[lrange $argv 1 end]"
    }
    se -
    search { ;# package search from local and OBS repos
        zypper_search "all" "[lrange $argv 1 end]"
    }
    lin -
    local-install { ;# package install with local repos only
        zypper_install "local" "[lrange $argv 1 end]"
    }
    oin -
    obs-install { ;# package install from OBS repos only
        zypper_install "obs" "[lrange $argv 1 end]"
    }
    in -
    install { ;# package install from local and OBS repos
        zypper_install "all" "[lrange $argv 1 end]"
    }
    if -
    info -
    pa -
    packages { ;# run these args with '--no-refresh' to save time
        zypper "--no-refresh $argv"
    }
    --help -
    ? -
    help { ;# output zow's help
        zow_help "[lrange $argv 1 end]"
    }
    -V -
    --version { ;# output zypper's and zow's version
        zypper "--version"
        puts "zow $version"
    }
    default { ;# any other arguments
        if {[llength $argv] == 0} { ;# output zow's help if no arguments
            zow_help ""
        } else { ;# else run zypper proc with arguments
            zypper "$argv"
        }
    }
}

# exit with exit code from zypper
exit $exitcode
