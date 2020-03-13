#!/usr/bin/env bash

SCRIPTDIR=`dirname "$0"`

cd $SCRIPTDIR

if [ `id -u` -ne 0 ]; then
    echo "Please run this script with sudo"
    exit 1
fi

set -o pipefail # trace ERR through pipes
set -o errtrace # trace ERR through 'time command' and other functions


# Creating logs folder
if [ ! -d "logs" ]; then
        mkdir logs
fi
chmod a+rwx logs


# Running the pathologies.json generator
echo -e "\nDo you want to auto-generate the config files? ( Y/N )"
read answer
while true
do
	if [[ ${answer} == "y" || ${answer} == "Y" ]]; then
		echo "Auto-generating the config files..."
		./config/pathologies_generator.py -n
		break
	elif [[ ${answer} == "n" || ${answer} == "N" ]]; then
		echo "You can change the configurations manually from the config folder."
		break
	else
		echo "$answer is not a valid answer! Try again... ( Y/N )"
		read answer
	fi
done


# CSVs and metadata validation
echo "Validating if the CSVs match with the metadata..."
chmod 775 config/convert-csv-dataset-to-db.py

# Removing previous .db files
rm -rf data/**/*.db

# Running the database creation script
python config/convert-csv-dataset-to-db.py -f data/ -t "master"

# Get the status code from previous command
py_script=$?

# If status code != 0 an error has occurred
if [[ ${py_script} -ne 0 ]]; then
    echo -e "\nThe CSVs could not be parsed using the metadata. Exiting..." >&2
    exit 1
else
    echo -e "\nThe CSVs match with the metadata."
fi


echo -e "\nRemoving previous services..."
docker-compose --project-name mip down

echo -e "\nDeploy Services..."
docker-compose --project-name mip up -d
