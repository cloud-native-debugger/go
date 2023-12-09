# @author Michael-Topchiev
# manual testing:
# awk -v name="dev-cloud-cpo" -f awk/check.awk "/mnt/c/Users/Michael/.ssh/config" || echo $?

BEGIN { 
  lookingForHost = 1 
}

# When the right Host found, start looking for host IP and port
{
  if (tolower($1) == "host" && $2 == name && 1 == lookingForHost) {
    lookingForHost=0
    lookingForHostName=1
    lookingForPort=1
  }
}

{
  if (tolower($1) == "host" && $2 != name) {
    lookingForHostName=0
    lookingForPort=0
  }
}

{
  if (tolower($1) == "hostname" && 1 == lookingForHostName) { 
    hostname=$2;
    lookingForHostName=0
  }
}

{
  if (tolower($1) == "port" && 1 == lookingForPort) { 
    port=$2;
    lookingForPort=0
  }
}

END {
  if ( lookingForHost == 1 ) {
    print "NA"
  } else {
    print hostname ":" port
  }
}
