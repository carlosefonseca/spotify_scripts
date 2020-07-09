#!/usr/bin/env bash

which terminal-notifier > /dev/null || brew install terminal-notifier

run() {
	git fetch
	git checkout -f origin/master --quiet
	DATE=$(date +"%Y.%m.%d %H:%M:%S")
	CURRENT=$($1)

	if [ ! -f last.log ]; then
		echo "$CURRENT -> NEW"
		echo $CURRENT > last.log
		return
	fi

	LAST=$(cat last.log)

	if [[ $CURRENT = $LAST ]]; then
		echo "$DATE: $CURRENT -> EQUAL"
	else
		echo "$DATE: $CURRENT -> DIFF"

		# if [ -x "$(command -v alerter)" ]; then
		# 	alerter -sound default -title "Notif Looper" -subtitle 'New Data!' -message "$CURRENT" -ignoreDnD
		# 	echo
		# else
			terminal-notifier -sound default -title "Notif Looper" -subtitle 'New Data!' -message $CURRENT -ignoreDnD
		# fi

		echo $CURRENT > last.log

	fi

}

let secs=$2*60

while true
do
	run $1
	sleep $secs
done
