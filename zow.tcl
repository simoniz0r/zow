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
http::register https 443 ::tls::socket

# set version
set version "0.1.00"

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
        if {[string first {--} $arg] == -1 && [string first {-} $arg] == 0} {
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

# proc that runs commands using bash
proc bash {command} {
    # set default values
    set ::err 0
    set ::stderr {}
    set ::stdout {}
    # run command and catch any non-zero exit
    if {[catch {exec bash -c "$command"} output] != 0} {
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

# proc that handles all generic zypper calls
proc zypper {arguments} {
    # run zypper piped to tee /dev/tty and exit with zypper's exit status
    # check if colors should be used
    color_config {/etc/zypp/zypper.conf}
    if {$::useColors == "false"} {
        bash "zypper $arguments | tee /dev/tty; exit \${PIPESTATUS\[0\]}"
    } else {
        bash "zypper --color $arguments | tee /dev/tty; exit \${PIPESTATUS\[0\]}"
    }
    # re-run zypper with sudo if exit is 5
    if {$::err == 5} {
        if {$::useColors == "false"} {
            bash "sudo zypper $arguments | tee /dev/tty; exit \${PIPESTATUS\[0\]}"
        } else {
            bash "sudo zypper --color $arguments | tee /dev/tty; exit \${PIPESTATUS\[0\]}"
        }
    }
    # ouput stderr if exit code is not 0
    if {$::err != 0 && [string last {child process exited abnormally} $::stderr] == -1} {
        puts stderr $::stderr
    }
}

# proc that decides which searches to run
proc zypper_search {repos package} {
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
proc zypper_search_local {package} {
    # get colors for output
    color_config {/etc/zypp/zypper.conf}
    # run zypper search
    bash "zypper --no-refresh --xmlout search $package"
    # trim xml just in case
    set xml [string trim $::stdout]
    # use tdom to parse xml
    set root [rest::format_tdom $xml]
    # get messages from xml
    set msgs [$root selectNodes {/stream/message/text()}]
    # output messages
    foreach msg $msgs {
        puts [$msg nodeValue]
    }
    # blank line
    puts {}
    # get search results from xml
    set results [$root selectNodes {/stream/search-result/solvable-list/solvable}]
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

# detect input
switch -exact -- [lindex $argv 0] {
    ch -
    changes { ;# use rpm to show changes file
        bash "rpm -q --changes [lrange $argv 1 end]"
        puts $::stdout
        if {$::err != 0 && [string last {child process exited abnormally} $::stderr] == -1} {
            puts stderr $::stderr
        }
    }
    lf -
    list-files { ;# use rpm to list files in package
        bash "rpm -q --filesbypkg [lrange $argv 1 end]"
        puts $::stdout
        if {$::err != 0 && [string last {child process exited abnormally} $::stderr] == -1} {
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
