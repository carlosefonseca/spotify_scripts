#!/usr/bin/env bash

update() {
	git fetch
	git checkout -f origin/main --quiet
	bundle install --quiet
}

run() {
	DATE=$(date +"%Y.%m.%d %H:%M:%S")
	CURRENT=$($1)

	if [ ! -f last.log ]; then
		echo "$CURRENT -> NEW"
		echo $CURRENT > last.log
		return
	fi

	LAST=$(cat last.log)

	if [[ $CURRENT = $LAST ]]; then
		echo "= $DATE: $CURRENT"
	else
		echo "! $DATE: $CURRENT"

		echo $CURRENT > last.log
	fi
}

if [ $# -eq 0 ];
then
	update
	exit
fi

let secs=$2*60

while true
do
	run $1
	sleep $secs
	update
done
