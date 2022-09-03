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
set version "0.1.02"

# proc that uses tput to set colors
proc color {foreground text} {
    switch -glob -- $foreground {
        *b {return [exec tput bold][exec tput setaf [lindex [split $foreground "b"] 0]]$text[exec tput sgr0]}
        default {return [exec tput setaf $foreground]$text[exec tput sgr0]}
    }
}

# proc that parses named colors into numbers
proc color_parse {color} {
    switch -exact $color {
        red {return 1}
        green {return 2}
        brown -
        yellow {return 3}
        blue {return 4}
        purple -
        magenta {return 5}
        cyan {return 6}
        gray {return 8}
        bold {return 7b}
        white -
        default {return 7}
    }
}

# proc that gets color config
proc color_config {path} {
    # set default colors
    set ::msgError 7
    set ::msgWarning 7
    set ::highlight 7
    set ::positive 7
    set ::change 7
    set ::prompt 7
    # catch error when opening
    if {[catch {open $path}] == 0} {
        # open and read config file
        set fileID [open $path]
        set file [read $fileID]
        # get useColors config option from file
        set ::useColors [lindex [split [lindex [regexp -inline -line -- {useColors\s=\s\w+} $file] 0] { }] 2]
        # if not found, set to false
        if {$::useColors == {}} {
            set ::useColors false
        }
        if {$::useColors != "false"} {
            # get colors from config file if useColors is not false
            set ::msgError [color_parse [lindex [split [lindex [regexp -inline -line -- {msgError\s=\s\w+} $file] 0] { }] 2]]
            set ::msgWarning [color_parse [lindex [split [lindex [regexp -inline -line -- {msgWarning\s=\s\w+} $file] 0] { }] 2]]
            set ::highlight [color_parse [lindex [split [lindex [regexp -inline -line -- {highlight\s=\s\w+} $file] 0] { }] 2]]
            set ::positive [color_parse [lindex [split [lindex [regexp -inline -line -- {positive\s=\s\w+} $file] 0] { }] 2]]
            set ::change [color_parse [lindex [split [lindex [regexp -inline -line -- {change\s=\s\w+} $file] 0] { }] 2]]
            set ::prompt [color_parse [lindex [split [lindex [regexp -inline -line -- {prompt\s=\s\w+} $file] 0] { }] 2]]
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
    # set default values
    set ::err 0
    set ::stderr {}
    set ::stdout {}
    # run command and catch any non-zero exit
    if {[catch {exec -keepnewline -- {*}$command} output] != 0} {
        global errorCode
        # ::err is exit code
        set ::err [lindex $errorCode end]
        # ::stderr is last line of output
        set ::stderr [lindex [split $output "\n"] end]
        # ::stdout is all lines except last of output
        set ::stdout [join [lrange [split $output "\n"] 0 end-1] "\n"]
    } else {
        # ::stdout is output
        set ::stdout $output
    }
}

# proc that runs commands and sends stdout directly to terminal instead of capturing it
proc exec_nocap {command} {
    # set default values
    set ::err 0
    set ::stderr {}
    chan configure stdout -buffering none
    # run command and catch any non-zero exit
    if {[catch {exec -keepnewline -- >@stdout {*}$command} output] != 0} {
        global errorCode
        # ::err is exit code
        set ::err [lindex $errorCode end]
        # ::stderr is output
        set ::stderr $output
    }
}

# proc that handles all generic zypper calls
proc zypper {arguments} {
    # run zypper through exec_nocap proc
    # check if colors should be used
    color_config {/etc/zypp/zypper.conf}
    if {$::useColors == "false"} {
        exec_nocap "zypper $arguments"
    } else {
        exec_nocap "zypper --color $arguments"
    }
    # re-run zypper with sudo if exit is 5
    if {$::err == 5} {
        if {$::useColors == "false"} {
            exec_nocap "sudo zypper $arguments"
        } else {
            exec_nocap "sudo zypper --color $arguments"
        }
    }
    # ouput stderr if exit code is not 0
    if {$::err != 0} {
        puts stderr $::stderr
    }
}

# proc that decides which searches to run
proc zypper_search {repos package} {
    # get colors for output
    color_config {/etc/zypp/zypper.conf}
    switch -exact -- $repos {
        all { ;# both OBS and local repos
            zypper_search_local "$package"
            zypper_search_obs "search" "$package"
        }
        obs { ;# only OBS repos
            zypper_search_obs "search" "$package"
        }
        local { ;# only local repos
            zypper_search_local "$package"
        }
    }
}

# proc that handles package search through zypper
proc zypper_search_local {arguments} {
    # run zypper search
    exec_cap "zypper --no-refresh --xmlout search $arguments"
    # trim xml just in case
    set zypper_results [string trim $::stdout]
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
            set nameColor $::positive
            set statusColor $::positive
        } elseif {[$result getAttribute status] == "other-version"} {
            set nameColor $::highlight
            set statusColor $::msgWarning
        } else {
            set nameColor $::highlight
            set statusColor 8
        }
        # output result, formatting depends on if summary attribute exists in result
        if {[catch {$result getAttribute summary}] == 0} {
            puts "[color $::prompt [color $nameColor [$result getAttribute name]]] | [$result getAttribute kind] | [color $statusColor [$result getAttribute status]]"
            puts "    [$result getAttribute summary]\n"
        } else {
            puts "[color $::prompt [color $nameColor [$result getAttribute name]]] |\
            [color $::change [$result getAttribute repository]] |\
            [$result getAttribute edition] |\
            [$result getAttribute arch] |\
            [$result getAttribute kind] |\
            [color $statusColor [$result getAttribute status]]\n"
        }
    }
}

# proc that handles searching OBS repos
proc zypper_search_obs {type arguments} {
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
        puts stderr [color $::msgError "Error opening {/etc/products.d/baseproduct}"]
        exit 1
    }
    set baseproduct [rest::format_tdom [read $baseproduct_id]]
    set release [regsub -all {\s} [$baseproduct selectNodes {string(/product/summary)}] {%253A}]
    # set URL to opi proxy
    set opi_proxy {https://opi-proxy.opensuse.org/?obs_api_link=}
    # output heading if $type is search
    if {$type == "search"} {
        puts "[color $::msgWarning "OBS search results:"]\n"
    }
    # loop through $packages
    foreach package $packages {
        # set query based on if -x or --match-exact flag used
        if {$exact == 1} {
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
            puts stderr [color $::msgError "Failed to get search results from $full_url."]
            exit 1
        }
        # use tdom to parse xml
        set xml [rest::format_tdom $obs_results]
        # check how many matches
        set collection [$xml selectNodes {/collection}]
        set matches [$collection getAttribute {matches}]
        if {$matches == 0} {
            if {$type != "search"} {
                return {}
            } else {
                puts {No matching items found.}
                exit 104
            }
        }
        set ::err 0
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
        if {$type != "search"} {
            return $binary_list
        } else {
            foreach binary $binary_list {
                puts "[color $::prompt [color $::highlight [$binary getAttribute name]]] |\
                [color $::change [$binary getAttribute project]] |\
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

# detect input
switch -exact -- [lindex $argv 0] {
    ch -
    changes { ;# use rpm to show changes file
        exec_nocap "rpm -q --changes [lrange $argv 1 end]"
        if {$::err != 0} {
            puts stderr $::stderr
        }
    }
    lf -
    list-files { ;# use rpm to list files in package
        exec_nocap "rpm -q --filesbypkg [lrange $argv 1 end]"
        if {$::err != 0} {
            puts stderr $::stderr
        }
    }
    lse -
    local-search { ;# package search with only local repos
        zypper_search "local" "[lrange $argv 1 end]"
    }
    ose -
    obs-search { ;# OBS package search only
        zypper_search "obs" "[lrange $argv 1 end]"
    }
    se -
    search { ;# package search both OBS and local repos
        zypper_search "all" "[lrange $argv 1 end]"
    }
    if -
    info -
    pa -
    packages {
        zypper "--no-refresh $argv"
    }
    default { ;# any other arguments
        zypper "$argv"
    }
}

# exit with exit code from zypper
exit $::err
