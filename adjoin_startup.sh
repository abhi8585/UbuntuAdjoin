#! /bin/bash
#
echo "domain:" $DOMAIN
echo "user to join:" $ADJOINER
echo "zone:" $ZONE 
echo "container:" $OU
echo "host name to use:" $NAME

# setup value for NSS auditing
echo "NSS auditing:" $ENABLE_NSS_AUDITING
NSSAuditing='Y'
	
if [ "$ENABLE_NSS_AUDITING" != "" ] ; then
   NSSAuditing=${ENABLE_NSS_AUDITING::1}
fi

# setup value for UseMyAccount
echo "ENABLE_USE_MY_ACCOUNT: $ENABLE_USE_MY_ACCOUNT" 
UseMyAccount='N'

if [ "$ENABLE_USE_MY_ACCOUNT" != "" ] ; then
    UseMyAccount=${ENABLE_USE_MY_ACCOUNT::1} 
fi


echo "current tenant URL: " $URL
echo "UseMyAccount: $UseMyAccount" 
echo "Enrollment Code: " $CODE
echo "IP address to use:" $ADDRESS
echo "current setting for PORT:" $PORT
echo "connectors setting: " $CONNECTOR


if [ "$DOMAIN" = "" ]; then
    echo "No DOMAIN specified."
    # exec /usr/sbin/init
fi

if [ "$ADJOINER" = "" ]; then
    echo "No ADJOINER specified."
    # exec /usr/sbin/init
fi

if [ "$ZONE" = "" ]; then
    echo "No ZONE specified."
    # exec /usr/sbin/init
fi

if [ "$URL" = "" ]; then
    echo "No URL specified."
    # exec /usr/sbin/init
fi

if [[ "$UseMyAccount" == "Y" || "$UseMyAccount" == "y" || "$UseMyAccount" == "T" || "$UseMyAccount" == "t" ]] ; then
    if [ "$URL" = "" ]; then
        echo "UseMyAccount is enabled but tenant URL is not specified."
        # exec /usr/sbin/init
    fi
    if [ "$CODE" = "" ]; then
        echo "UseMyAccount is enabled but Enrollment code is not specified."
        # exec /usr/sbin/init
    fi
    if [ "$ADDRESS" = "" ]; then
        echo "UseMyAccount is enabled but IP Address of host is not specified."
        # exec /usr/sbin/init
    fi
    if [ "$PORT" = "" ]; then
        echo "UseMyAccount is enabled but External Port of host is not specified."
        # exec /usr/sbin/init
    fi
    if [ "$CONNECTOR" = "" ]; then
        echo "if UseMyAccount is enabled and an appropriate Connector is not specified, it may fail."
    fi
fi

# touch all ignore files to set link count to 1

touch /etc/centrifydc/*.ignore

# set up command line parameters

CMDPARAM=()

if [ "$OU" != "" ]; then
    CMDPARAM=("${CMDPARAM[@]}" "--container" "$OU")
fi

if [ "$NAME" != "" ]; then
    CMDPARAM=("${CMDPARAM[@]}" "--name" "$NAME")
fi

if [ "$COMPUTER_ROLES" != "" ] ; then
    # convert the string into an array for set up roles
    IFS=","
    for computer_role in $COMPUTER_ROLES
    do 
      CMDPARAM=("${CMDPARAM[@]}" "-R" "$computer_role")
    done
fi
    
if [ "$ADJOIN_OPTION" != "" ] ; then
    # convert the string into an array for passing into adjoin
    IFS=' ' read -a tempoption <<< "${ADJOIN_OPTION}"
    CMDPARAM=("${CMDPARAM[@]}" "${tempoption[@]}")
fi


echo https://$URL/servermanage/getmastersshkey

if [[ "$UseMyAccount" == "Y" || "$UseMyAccount" == "y" || "$UseMyAccount" == "T" || "$UseMyAccount" == "t" ]] ; then
    # set up sshd config
    if [ ! -f /etc/ssh/sshd_config.bak ] ; then
        cp /etc/ssh/sshd_config /etc/ssh/sshd_config.bak
        sed -i -e '/^TrustedUserCAKeys/d' -e '/^AuthorizedPrincipalsCommand/d' /etc/ssh/sshd_config
        echo "AuthorizedPrincipalsCommand /usr/bin/adquery user -P %u" >> /etc/ssh/sshd_config
        echo "AuthorizedPrincipalsCommandUser root" >> /etc/ssh/sshd_config
        echo "TrustedUserCAKeys /etc/ssh/cps_ca.pub" >> /etc/ssh/sshd_config
    fi
    /usr/share/centrifydc/bin/curl -o /etc/ssh/cps_ca.pub https://$URL/servermanage/getmastersshkey    
fi


# giving permissions to /usr/sbin because this is not direct editable.

chmod -R 777 $(whoami) /usr/sbin/*


(
    echo "`date`: ready to join "
    echo " parameters: [${CMDPARAM[@]}]"
    set -e
    
    # obtain credential to join
    echo "obtaining credential ..."
    mv /etc/krb5.conf /etc/krb5.conf.bak || true
    /usr/share/centrifydc/kerberos/bin/kinit -kt \
        /etc/centrifydc/adjoiner.keytab -C 	$ADJOINER
    
    # leave the system from the domain if joined
    /usr/sbin/adleave -r && sleep 3 || true

    # join system to AD
    
    # the adjoin option -I requires Release 18.11 or later.
    #
    echo "joining the system to AD ..."	
    RC=0
    /usr/sbin/adjoin -V -I $DOMAIN -z $ZONE "${CMDPARAM[@]}" --force     || RC=$?
    if [ $RC -eq 0 ]; then
        # enable the service so that it will be started by systemd later on
        echo "starting device	"
        /usr/bin/systemctl enable centrifydc.service
    else
        echo "adjoin failed."
        false
    fi

) 2>&1 | tee -a /var/centrify/adjoin.log

if [ -x /usr/sbin/dad ]; then
    (
        echo "`date`: enable auditing service"
        set -e

        # enable auditing service, it should be running at anytime
        systemctl enable centrifyda.service || true

        # start auditing service for configuration
        /usr/share/centrifydc/bin/centrifyda start || true

        # enable or disable NSS auditing
        if [[ "$NSSAuditing" == "Y" || "$NSSAuditing" == "y" || "$NSSAuditing" == "T" || "$NSSAuditing" == "t" ]] ; then
            echo "enable NSS auditing "
            /usr/sbin/dacontrol -e || true
        else
            echo "disable NSS auditing "
            /usr/sbin/dacontrol -d || true
        fi

        # set audit installation
        if [ -n "$INSTALLATION" ]; then

            echo "set audit installation to $INSTALLATION"
            /usr/sbin/dacontrol -i "$INSTALLATION" || true            

            # the new installation setting will take effect once
            # the auditing service is started by systemd later.
        fi

        # checkapt-get update current settings
        /usr/sbin/dacontrol -q || true

    ) 2>&1 | tee -a /var/centrify/adjoin.log
fi

(
    echo "stop Centrify DirectControl"
    /usr/share/centrifydc/bin/centrifydc stop

    if [ -x /usr/sbin/dad ]; then
        echo "stop Centrify DirectAudit"
        /usr/share/centrifydc/bin/centrifyda stop
    fi

) 2>&1 | tee -a /var/centrify/adjoin.log

(
    echo "stop Centrify DirectControl"
    /usr/share/centrifydc/bin/centrifydc stop

    if [ -x /usr/sbin/dad ]; then
        echo "stop Centrify DirectAudit"
        /usr/share/centrifydc/bin/centrifyda stop
    fi

) 2>&1 | tee -a /var/centrify/adjoin.log


# stop now, the service will be started by systemd later
(
    echo "stop Centrify DirectControl"
    /usr/share/centrifydc/bin/centrifydc stop

    if [ -x /usr/sbin/dad ]; then
        echo "stop Centrify DirectAudit"
        /usr/share/centrifydc/bin/centrifyda stop
    fi

) 2>&1 | tee -a /var/centrify/adjoin.log


# change password if specified
if [ "$ROOT_PASSWORD" != "" ] ; then
    echo "set root password "
    echo "$ROOT_PASSWORD" | passwd --stdin root
else
    echo "generate root password "
    user=root
    paswd=`/usr/share/centrifydc/bin/openssl rand -base64 16`
    "$USR:$PASS" | chpasswd
    #/usr/share/centrifydc/bin/openssl rand -base64 16 | passwd --stdin root
fi

echo "Yes it is working!!"

echo "start the container"
echo "reached to the end"
echo "gotcha man!!"
exec /usr/sbin/init RUNLEVEL=6 PREVLEVEL=5 
# echo "yes it is working fine"
# exec /lib/systemd/systemd  

# exec systemctl start reboot.target
# /usr/sbin/init systemctl
