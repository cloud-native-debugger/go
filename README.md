## Installation
- Clone this repository into any directory
  ```
  git clone git@github.ibm.com:Michael-Topchiev/cloud-native-go-debugger.git ~/debugger
  ```
- Modify config/globals to use your preferences
- Create links to the scripts in any folder on the path
  ```
  ln -s $HOME/debugger/debug-start.sh /usr/local/bin/debug-start
  ln -s $HOME/debugger/debug-stop.sh /usr/local/bin/debug-stop
  ```

## Debugging
- Log in to an image registry
  ```
  docker login -u="my-uid" -p="my-pwd" quay.io
  ```
- Log in to a cluster with admin access
  ```
  export KUBECONFIG=$HOME/kubeconfig/bm-fra-3.kubeconfig
  ```
- Begin debugging. Ex. to debug HO
  ```
  debug-start ho hypershift
  ```
- Restore the service deployment when done
  ```
  debug-stop ho hypershift
  ```

## Notes
- By default debug-start uses one of the cluster node IP address to connect to the debugger. To use different IP address, ex. public IP address of a cluster node, specify the address as the 3rd parameter `debug-start ho hypershift 150.239.24.229`
- The debugger image will not be built if it is already available in the image registry. To force re-building and re-uploading the image `debug-start ho hypershift -f`
