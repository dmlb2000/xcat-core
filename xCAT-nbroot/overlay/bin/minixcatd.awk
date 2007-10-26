#!/usr/bin/awk -f
# IBM(c) 2007 EPL license http://www.eclipse.org/legal/epl-v10.html
BEGIN {
	port = 3001
	listener = "/inet/tcp/" port "/0/0"
    quit = "no"
	while (match(quit,"no")) {
      print quit;
		while (match(quit,"no") && (listener |& getline) > 0) {
			if (match($0,"restart")) {
				print "restarting bootstrap process" |& listener
                quit="yes"
				system("touch /restart")
				system("killall usleep")
		        close(listener)
			}
		}
		close(listener)
	}
}
