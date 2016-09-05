#!/bin/bash
# This file should be generated by our ServicePanel, and provisioned with the SSH-keys that the customer has on his Hypernode

set -e

while getopts "m:v:f:" opt; do
    case "$opt" in
        m)
            magento_version="$OPTARG" ;;
        v)
            varnish_enabled="$OPTARG" ;;
        f)
            firewall_enabled="$OPTARG" ;;
    esac
done

truncate -s 0 /var/mail/app

user="app"
homedir=$(getent passwd $user | cut -d ':' -f6)
mkdir -p /root/.ssh
sudo -u $user mkdir -p "$homedir/.ssh"
touch /root/.ssh/authorized_keys
sudo -u $user touch "$homedir/.ssh/authorized_keys"
chmod 700 /root/.ssh "$homedir/.ssh"
chmod 600 /root/.ssh/authorized_keys "$homedir/.ssh/authorized_keys"

if ssh-add -L >/dev/null 2>/dev/null; then
    user_combined=$(ssh-add -L | awk '!NF || !seen[$0]++' "$homedir/.ssh/authorized_keys" -)
    echo "$user_combined" > "$homedir/.ssh/authorized_keys"
    root_combined=$(ssh-add -L | awk '!NF || !seen[$0]++' /root/.ssh/authorized_keys -)
    echo "$root_combined" > "/root/.ssh/authorized_keys"
fi

cat << EOF >> $homedir/.ssh/authorized_keys
ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAACAQDSERHiEjdibIowB763wgGn4OCdko4b8WfqmgihgiIsVIX76RP6oTgAO9uqkNkirYilCT0DF33CGk06h1DkqRZ4mUN3bNNz+tlFBwJnT/sAj4gPe6rt1hK68m55p1SZRrMPbLyFPM0XUWSvVzJd8hSwIOEFgc5Igcj1OvJz2MqlSlRrRgi1ageAlIofoRh6G2JMqRVAQiBKLCvzT0KDEoionkC/kDWckDOLApVKof2dzsiG2WmV2nZrVyvwJPNBAUYiTZ53JrMqy491ojs/PvnPlJpvXgHMTEHIyt3hNKyJIRtDukzZBldayGV1dsj0SPXxWPqnc898rc6PQpL9IKSRDn1uxWKPeQ7WYYTl1uV4E30setuAILazRoS2EXdCD+nKZd9gw0h3YuZYKChjKeNWAdNHR46s6AGJDHTIYmgksrLiTPM/c7joSlpexi+/FrUJF5VOB2X/uul17Es7IWILdlgGnAIHpbLBw71j3gamGU3+ciaCrblB7FZJtxbiG7wXAL0MQIHdF3LOrPrBONVqOXA2VlpEHyerCMkXyc7U5sFosV8mlqPUGocDzGQx6y7tCuCE6KxLyoaDiENYnQOyiTg1cXbQTd7m6Z6kkIEXLT/vHKLxqXW1qCjV8dS4U5Rfx8B2GkCP0sWstR1XWRTNCBUnzfN3NztCBR8PsrZ/yw== vagrant@deploy
ssh-rsa AAAAB3NzaC1yc2EAAAABIwAAAQEA6NF8iallvQVp22WDkTkyrtvp9eWW6A8YVr+kz4TjGYe7gHzIw+niNltGEFHzD8+v1I2YJ6oXevct1YeS0o9HZyN1Q9qgCgzUFtdOKLv6IedplqoPkcmF0aYet2PkEDo3MlTBckFXPITAMzF8dJSIFo9D8HfdOV0IAdx4O7PtixWKn5y2hMNG0zQPyUecp4pzC6kivAIhyfHilFR61RGL+GPXQ2MWZWFYbAGjyiYJnAmCP3NOTd0jMZEnDkbUvxhMmBYSdETk1rRgm+R4LOzFUGaHqHDLKLX+FIPKcF96hrucXzcWyLbIbEgE98OHlnVYCzRdK8jlqm8tehUc9c9WhQ== vagrant insecure public key
EOF

if [ "$HOSTNAME" != "xxxxx-dummytag-vagrant.nodes.hypernode.io" ]; then
    rm -f "/var/lib/varnish/$HOSTNAME"
    ln -s /var/lib/varnish/xxxxx-dummytag-vagrant.nodes.hypernode.io/ "/var/lib/varnish/`hostname`"
fi

rm -rf /etc/cron.d/hypernode-fpm-monitor

# Copy default nginx configs to synced nginx directory if the files don't exist
if [ -d /etc/hypernode/defaults/nginx/ ]; then
    find /etc/hypernode/defaults/nginx -type f | sudo -u $user xargs -I {} cp -n {} /data/web/nginx/
fi

if [ "$magento_version" == "2" ]; then
    # Create magento 2 nginx flag file
    sudo -u $user touch /data/web/nginx/magento2.flag
    # Set correct symlink
    rm -rf /data/web/public
    sudo -u $user mkdir -p /data/web/magento2/pub  
    # Create pub dir if it does not exist yet
    sudo -u $user ln -fs /data/web/magento2/pub /data/web/public
else
    sudo -u $user rm -f /data/web/nginx/magento2.flag
fi

# ensure varnish is running. in lxc vagrant boxes for some reason the varnish init script in /etc/init.d doesn't bring up the service on boot
# todo: find out why varnish isn't always started on startup on lxc instances
ps -ef | grep -v "grep" | grep varnishd -q || (service varnish start && sleep 1)

# if the webroot is empty, place our default index.php which shows the settings
if ! find /data/web/public/ -mindepth 1 -name '*.php' -name '*.html' | read; then
    sudo -u $user cp /vagrant/vagrant/resources/*.{php,js,css} /data/web/public/
fi

if ! $varnish_enabled; then
    su $user -c "echo -e 'vcl 4.0;\nbackend default {\n .host = \"127.0.0.1\";\n .port= \"8080\";\n}\nsub vcl_recv {\n return(pass);\n}' > /data/web/disabled_caching.vcl"
    varnishadm vcl.load nocache /data/web/disabled_caching.vcl
    varnishadm vcl.use nocache
fi

# ufw is disabled by default with an upstart override in the boxfile image because sometimes 
# the firewall gets in the way when mounting the directories with specific synced folder fs types
if $firewall_enabled; then
    rm -f /etc/init/ufw.override
fi
    
touch "$homedir/.ssh/authorized_keys"

echo "Your hypernode-vagrant is ready! Log in with:"
echo "ssh app@hypernode.local -oStrictHostKeyChecking=no -A"
echo "Or visit https://$(echo `hostname` | cut -d'-' -f2).hypernode.local in your browser"
