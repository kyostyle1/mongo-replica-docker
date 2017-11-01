function howManyServers {
  arg=''
  c=0
  for server in manager1 worker1 worker2
  do
      cmd='docker-machine ip '$server
      arg=$arg' --add-host '${server}':'$($cmd)
  done

  echo $arg
}

function switchToServer {
  env='docker-machine env '$1
  eval $($env)
}

function startReplicaSet {
  wait_for_databases $2 "$4"
  docker exec -i $1 bash -c 'mongo --eval "rs.initiate() && rs.conf()" --port '$p' -u $MONGO_SUPER_ADMIN -p $MONGO_PASS_SUPER --authenticationDatabase="admin"'
}

function createDockerVolume {
  cmd=$(docker volume ls -q | grep $1)
  if [[ "$cmd" == $1 ]];
  then
    echo 'volume available'
  else
    cmd='docker volume create --name '$1
    eval $cmd
  fi
}

function copyFilesToContainer {
  docker cp ./admin.js $1:/data/admin/
  docker cp ./replica.js $1:/data/admin/
  docker cp ./mongo-keyfile $1:/data/keyfile/
  docker cp ./grantRole.js $1:/data/admin
}

function configMongoContainer {
  createDockerVolume $2
  docker run --name $1 -v $2:/data -d mongo --smallfiles
  docker exec -i $1 bash -c 'mkdir /data/keyfile /data/admin'
  copyFilesToContainer $1
  docker exec -i $1 bash -c 'chown -R mongodb:mongodb /data'
}

function removeAndCreateContainer {
  docker rm -f $1

  env='./env'
  serv=$(howManyServers)
  keyfile='mongo-keyfile'
  port='27017:27017'
  p='27017'
  rs='rs1'

  docker run --restart=unless-stopped --name $1 --hostname $1 \
  -v $2:/data \
  --env-file $env \
  $serv \
  -p $port \
  -d mongo --smallfiles \
  --keyFile /data/keyfile/$keyfile \
  --replSet $rs \
  --storageEngine wiredTiger \
  --port $p
}

function createMongoDBNode {
  switchToServer $1
  configMongoContainer $2 $3

  sleep 2
  removeAndCreateContainer $2 $3
  wait_for_databases 'manager1'
}

function wait_for {
  start_ts=$(date +%s)
  while :
  do
    (echo > /dev/tcp/$1/$2) >/dev/null 2>&1
    result=$?
    if [[ $result -eq 0 ]]; then
        end_ts=$(date +%s)
        sleep 3
        break
    fi
    sleep 5
  done
}

function wait_for_databases {
  if [[ ($1 == 'manager1') ]]; then
    ip=$(docker-machine ip manager1)
  elif [[ $1 == 'worker1' ]]; then
    ip=$(docker-machine ip worker1)
  elif [[ $1 == 'worker2' ]]; then
    ip=$(docker-machine ip worker2)
  fi

  echo "IP == $ip PORT == 27017"
  wait_for "$ip" 27017
}

function createKeyFile {
  openssl rand -base64 741 > $1
  chmod 600 $1
}

function add_replicas {
  switchToServer $1

  for server in worker1 worker2
  do
    rs="rs.add('$server:27017')"
    add='mongo --eval "'$rs'" -u $MONGO_REPLICA_ADMIN -p $MONGO_PASS_REPLICA --authenticationDatabase="admin"'
    sleep 2
    wait_for_databases $server
    docker exec -i $2 bash -c "$add"
  done
}

function init_replica_set {
  docker exec -i $1 bash -c 'mongo < /data/admin/replica.js'
  sleep 2
  docker exec -i $1 bash -c 'mongo < /data/admin/admin.js'
  cmd='mongo -u $MONGO_REPLICA_ADMIN -p $MONGO_PASS_REPLICA --eval "rs.status()" --authenticationDatabase "admin"'
  sleep 2
  docker exec -i mongoNode1 bash -c "$cmd"
}

function init_mongo_primary {
  createKeyFile mongo-keyfile
  createMongoDBNode manager1 mongoNode1 mongo_storage
  init_replica_set mongoNode1
}

function init_mongo_secondaries {
  createMongoDBNode worker1 mongoNode2 mongo_storage
  createMongoDBNode worker2 mongoNode3 mongo_storage
}

function check_status {
  switchToServer $1
  cmd='mongo -u $MONGO_REPLICA_ADMIN -p $MONGO_PASS_REPLICA --eval "rs.status()" --authenticationDatabase "admin"'
  docker exec -i $2 bash -c "$cmd"
}

function add_db_test {
  docker exec -i mongoNode1 bash -c 'mongo -u $MONGO_USER_ADMIN -p $MONGO_PASS_ADMIN --authenticationDatabase "admin" < /data/admin/grantRole.js'
}

function main {
  init_mongo_primary
  init_mongo_secondaries
  add_replicas manager1 mongoNode1
  check_status manager1 mongoNode1
  add_db_test
}

main
