{
  k8s-0 = {
    ip = "192.168.8.5";
    user = "root";
    interface = "eno1";
    gateway = "192.168.8.1";
    nameservers = [ "1.1.1.1" ];
    swarmRole = "manager";
    swarmAdvertiseAddr = "192.168.8.5";
    swarmManagerAddress = null;
    osDisk = "/dev/nvme0n1";
    dataDisk = "/dev/sda";
    ssdCacheGB = 75;
    tags = [ "manager" "bootstrap" ];
  };

  k8s-1 = {
    ip = "192.168.8.6";
    user = "root";
    interface = "eno2";
    gateway = "192.168.8.1";
    nameservers = [ "1.1.1.1" ];
    swarmRole = "manager";
    swarmAdvertiseAddr = "192.168.8.6";
    swarmManagerAddress = "192.168.8.5";
    osDisk = "/dev/nvme0n1";
    dataDisk = "/dev/sda";
    ssdCacheGB = 75;
    tags = [ "manager" ];
  };

  k8s-2 = {
    ip = "192.168.8.7";
    user = "root";
    interface = "eno1";
    gateway = "192.168.8.1";
    nameservers = [ "1.1.1.1" ];
    swarmRole = "manager";
    swarmAdvertiseAddr = "192.168.8.7";
    swarmManagerAddress = "192.168.8.5";
    osDisk = "/dev/nvme0n1";
    dataDisk = "/dev/sda";
    ssdCacheGB = 75;
    tags = [ "manager" ];
  };
}
