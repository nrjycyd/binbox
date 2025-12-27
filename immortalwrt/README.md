下载地址：[https://downloads.immortalwrt.org/](https://downloads.immortalwrt.org/)

预构建地址：[https://firmware-selector.immortalwrt.org/](https://firmware-selector.immortalwrt.org/)

```
型号：Generic x86/64
平台：x86/64
版本：24.10.4 
```

预安装的软件包（添加）：

```
luci-i18n-package-manager-zh-cn openssh-sftp-server snmpd bash
```

首次启动时运行的脚本（uci-defaults）:

```
# 开机后修改默认IP
uci set network.lan.ipaddr='192.168.3.199'; uci commit network; /etc/init.d/network restart
```
