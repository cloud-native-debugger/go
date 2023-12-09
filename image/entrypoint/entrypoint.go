package main

import (
	"log"
	"os"
	"os/exec"
	"strings"
)

func main() {
	path := "/etc/profile.d/99-dev.sh"
	f, err := os.Create(path)
	if err != nil {
		log.Fatal(err)
	}
	for _, element := range os.Environ() {
		if strings.HasPrefix(element, "PATH") || strings.HasPrefix(element, "HOME") {
			continue
		}
		_, err := f.WriteString("export " + element + "\n")
		if err != nil {
			log.Fatal(err)
		}
	}
	f.Sync()

	cmd := exec.Command("/usr/sbin/sshd", "-D", "-e", "-p", "2222")
	cmd.Stdout = os.Stdout
	cmd.Stderr = os.Stderr
	cmd.Run() // to kill: kill -9 `sudo lsof -t -i:22`
}
