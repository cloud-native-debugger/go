# @author Michael-Topchiev
# manual testing:
# awk -i inplace -v name="dev-cloud-nto" -v ip="127.0.0.1" -v port="32233" -v INPLACE_SUFFIX=.bak -f awk/replace.awk "/mnt/c/Users/Michael/.ssh/config" || echo $?

BEGIN { 
  lookingForHost = 1 
}

# When the right Host found, start looking for host IP and port
{
  if (tolower($1) == "host" && $2 == name && lookingForHost == 1) {
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
  if (tolower($1) == "hostname" && lookingForHostName == 1) { 
    sub( $2, ip );
    lookingForHostName=0
    hostNameUpdated=1
  }
}

{
  if (tolower($1) == "port" && lookingForPort == 1) { 
    sub( $2, port );
    lookingForPort=0
    portUpdated=1
  }
}

{ print }

END {
  if ( lookingForHost == 1 || hostNameUpdated != 1 || portUpdated != 1) {
    exit 9
  }
}
