let help = (react-doctor --help | str join "\n")

if not ($help | str contains "react-doctor") {
  error make { msg: "react-doctor help output did not identify the command" }
}

print "react-doctor: help is available"
