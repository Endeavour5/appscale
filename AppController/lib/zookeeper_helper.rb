require 'djinn'


# The location on the local filesystem where we should store ZooKeeper data.
DATA_LOCATION = "/opt/appscale/zookeeper"

ZOOKEEPER_PORT="2181"

# The path in ZooKeeper where the deployment ID is stored.
DEPLOYMENT_ID_PATH = '/appscale/deployment_id'

def configure_zookeeper(nodes, my_index)
  # TODO: create multi node configuration
  zoocfg = <<EOF
tickTime=2000
initLimit=10
syncLimit=5
dataDir=#{DATA_LOCATION}
clientPort=2181
leaderServes=yes
maxClientsCnxns=0
forceSync=no
skipACL=yes
autopurge.snapRetainCount=5
# Increased zookeeper activity can produce a vast amount of logs/snapshots.
# With this we ensure that logs/snapshots are cleaned up hourly.
autopurge.purgeInterval=1
EOF
  myid = ""

  zoosize = nodes.count { |node| node.is_zookeeper? }

  if zoosize > 1
    # from 3.4.0, server settings is valid only in two or more nodes.
    zooid = 1
    nodes.each_with_index { |node,index|
      if node.is_zookeeper?
        zoocfg += <<EOF
server.#{zooid}=#{node.private_ip}:2888:3888
EOF
        if index == my_index
          myid = zooid.to_s
        end
        zooid += 1
      end
    }
  end

  Djinn.log_debug("zookeeper configuration=#{zoocfg}")
  File.open("/etc/zookeeper/conf/zoo.cfg", "w+") { |file| file.write(zoocfg) }

  Djinn.log_debug("zookeeper myid=#{myid}")
  File.open("/etc/zookeeper/conf/myid", "w+") { |file| file.write(myid) }

  # set max heap memory
  Djinn.log_run("sed -i s/^JAVA_OPTS=.*/JAVA_OPTS=\"-Xmx1024m\"/ /etc/zookeeper/conf/environment")
end

def start_zookeeper(clear_datastore)
  if clear_datastore
    Djinn.log_run("rm -rfv /var/lib/zookeeper")
    Djinn.log_run("rm -rfv #{DATA_LOCATION}")
  end

  # Detect which version of zookeeper script we have.
  zk_server="zookeeper-server"
  if system("service --status-all|grep zookeeper$")
    zk_server="zookeeper"
  end

  if !File.directory?("#{DATA_LOCATION}")
    Djinn.log_info("Initializing ZooKeeper.")
    # Let's stop zookeeper in case it is still running.
    system("/usr/sbin/service #{zk_server} stop")

    # Let's create the new location for zookeeper.
    Djinn.log_run("mkdir -pv #{DATA_LOCATION}")
    Djinn.log_run("chown -Rv zookeeper:zookeeper #{DATA_LOCATION}")

    # Only precise (and zookeeper-server) has an init function.
    if zk_server == "zookeeper-server"
      if not system("/usr/sbin/service #{zk_server} init")
        Djinn.log_error("Failed to start zookeeper!")
        raise Exception FailedZooKeeperOperationException.new("Failed to" +
          " start zookeeper!")
      end
    end
  end

  # myid is needed for multi node configuration.
  Djinn.log_run("ln -sfv /etc/zookeeper/conf/myid #{DATA_LOCATION}/myid")

  start_cmd = "/usr/sbin/service #{zk_server} start"
  stop_cmd = "/usr/sbin/service #{zk_server} stop"
  match_cmd = "org.apache.zookeeper.server.quorum.QuorumPeerMain"
  MonitInterface.start(:zookeeper, start_cmd, stop_cmd, [ZOOKEEPER_PORT], nil,
                       match_cmd, nil, nil)
end

def is_zookeeper_running?
  output = MonitInterface.is_running?(:zookeeper)
  Djinn.log_debug("Checking if zookeeper is already monitored: #{output}")
  return output
end

def stop_zookeeper
  Djinn.log_info("Stopping ZooKeeper")
  MonitInterface.stop(:zookeeper)
end
