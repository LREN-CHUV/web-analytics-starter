#!/usr/bin/env bash

#
# Start the Web portal and the analytics engine (Woken)
#
# Option:
#   --no-frontend: do not start the frontend
#

set -o pipefail  # trace ERR through pipes
set -o errtrace  # trace ERR through 'time command' and other functions
set -o errexit   ## set -e : exit the script if any statement returns a non-true return value

get_script_dir () {
     SOURCE="${BASH_SOURCE[0]}"

     while [ -h "$SOURCE" ]; do
          DIR="$( cd -P "$( dirname "$SOURCE" )" && pwd )"
          SOURCE="$( readlink "$SOURCE" )"
          [[ $SOURCE != /* ]] && SOURCE="$DIR/$SOURCE"
     done
     cd -P "$( dirname "$SOURCE" )"
     pwd
}

cd "$(get_script_dir)"

frontend=1
for param in "$@"
do
  if [ "--no-frontend" == "$param" ]; then
    frontend=0
    echo "INFO: --no-frontend option detected !"
  fi
done

if pgrep -lf sshuttle > /dev/null ; then
  echo "sshuttle detected. Please close this program as it messes with networking and prevents Docker links to work"
  exit 1
fi

if [[ $NO_SUDO || -n "$CIRCLECI" ]]; then
  DOCKER_COMPOSE="docker-compose --project-name webanalyticsstarter"
elif groups "$USER" | grep &>/dev/null '\bdocker\b'; then
  DOCKER_COMPOSE="docker-compose --project-name webanalyticsstarter"
else
  DOCKER_COMPOSE="sudo docker-compose --project-name webanalyticsstarter"
fi

function _cleanup() {
  local error_code="$?"
  echo "Stopping the containers..."
  $DOCKER_COMPOSE stop | true
  $DOCKER_COMPOSE down | true
  $DOCKER_COMPOSE rm -f > /dev/null 2> /dev/null | true
  exit $error_code
}
trap _cleanup SIGINT SIGQUIT

export HOST=$(hostname)

echo "Remove old running containers (if any)..."
$DOCKER_COMPOSE kill
$DOCKER_COMPOSE rm -f

echo "Deploy a Postgres server and wait for it to be ready..."
$DOCKER_COMPOSE up -d db zookeeper
$DOCKER_COMPOSE run wait_zookeeper
$DOCKER_COMPOSE up -d mesos_master
$DOCKER_COMPOSE run wait_mesos_master
$DOCKER_COMPOSE up -d mesos_slave
$DOCKER_COMPOSE run wait_dbs

echo "Create databases..."
$DOCKER_COMPOSE run create_dbs

echo "Migrate woken database..."
$DOCKER_COMPOSE run woken_db_setup

echo "Migrate metadata database..."
$DOCKER_COMPOSE run sample_meta_db_setup

echo "Migrate features database..."
$DOCKER_COMPOSE run sample_data_db_setup

echo "Run containers..."
for i in 1 2 3 4 5 ; do
  $DOCKER_COMPOSE up -d chronos
  $DOCKER_COMPOSE run wait_chronos
  $DOCKER_COMPOSE logs chronos | grep java.util.concurrent.TimeoutException || break
  echo "Chronos failed to start, restarting..."
  $DOCKER_COMPOSE stop chronos
done

$DOCKER_COMPOSE up -d woken
$DOCKER_COMPOSE run wait_woken

$DOCKER_COMPOSE up -d wokenvalidation
$DOCKER_COMPOSE run wait_wokenvalidation

for i in 1 2 3 4 5 ; do
  $DOCKER_COMPOSE logs chronos | grep java.util.concurrent.TimeoutException || break
  echo "Chronos failed to start, restarting..."
  $DOCKER_COMPOSE stop chronos
  $DOCKER_COMPOSE up -d chronos
  $DOCKER_COMPOSE run wait_chronos
done

echo "The Algorithm Factory is now running on your system"

if [ $frontend == 1 ]; then
  FRONTEND_URL=http://frontend \
	  $DOCKER_COMPOSE up -d portalbackend
  $DOCKER_COMPOSE run wait_portal_backend
  $DOCKER_COMPOSE up -d frontend

  echo ""
  echo "System up!"
  echo "Useful URLs:"
  echo "  http://frontend/ : the Web portal"
  echo "  http://localhost:8080/services/swagger-ui.html : Swagger admin interface for backend"
  echo "  http://localhost:8087 : Swagger admin interface for Woken"
else
  FRONTEND_URL=http://localhost:8000 \
	$DOCKER_COMPOSE up -d portalbackend
  $DOCKER_COMPOSE run wait_portal_backend
  echo ""
  echo "System up!"
  echo "Useful URLs:"
  echo "  http://localhost:8080/services/swagger-ui.html : Swagger admin interface for backend"
  echo "  http://localhost:8087 : Swagger admin interface for Woken"
fi
