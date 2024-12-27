#!/bin/bash

# Author: chrisdhebert@gmail.com
# Version: 2.2024-12-26

# Variables
CWD="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MSFBIN="/usr/bin/msfconsole"
EYEWITNESS="/usr/bin/eyewitness"
DB="msf"
SERVICE="postgresql"
RESULTS="$CWD/results"
CONF="$CWD/conf"
LOGFILE="$CWD/sniper.log"
TEMPFILE=$(mktemp /tmp/sniper.XXXXXX) || { echo "Failed to create temporary file"; exit 1; }

# Logging Setup
exec > >(tee -a "$LOGFILE") 2>&1
echo "$(date '+%Y-%m-%d %H:%M:%S') - Script started."

# Function to check and start services
check_and_start_service() {
    local service_name="$1"
    if systemctl is-active --quiet "$service_name"; then
        echo "$(date '+%Y-%m-%d %H:%M:%S') - (OK) Found $service_name service running."
    else
        echo "$(date '+%Y-%m-%d %H:%M:%S') - (OK) Starting $service_name service..."
        systemctl start "$service_name"
        if systemctl is-active --quiet "$service_name"; then
            echo "$(date '+%Y-%m-%d %H:%M:%S') - (OK) $service_name started successfully."
        else
            echo "$(date '+%Y-%m-%d %H:%M:%S') - (ERROR) Failed to start $service_name."
            exit 1
        fi
    fi
}

# Function to check required commands
check_command() {
    local cmd="$1"
    if ! command -v "$cmd" &> /dev/null; then
        echo "$(date '+%Y-%m-%d %H:%M:%S') - (ERROR) Required command $cmd not found. Please install it."
        exit 1
    fi
}

# Function to handle new Nmap imports
import_nmap_files() {
    if ls "$RESULTS/new/"*.* &> /dev/null; then
        echo "$(date '+%Y-%m-%d %H:%M:%S') - (OK) Importing newer Nmap files to $DB database."
        cp "$CONF/msf_default.rc" "$CONF/msf.rc"
        echo "db_import $RESULTS/new/*.xml" >> "$CONF/msf.rc"
        echo "quit -y" >> "$CONF/msf.rc"
        $MSFBIN -r "$CONF/msf.rc"
        mv "$RESULTS/new/"*.xml "$RESULTS/import_complete"
        echo "$(date '+%Y-%m-%d %H:%M:%S') - (OK) Nmap DB Import Complete."
    else
        echo "$(date '+%Y-%m-%d %H:%M:%S') - (OK) No new Nmap files to import."
    fi
}

# Function to count total hosts in the database
count_total_hosts() {
    TOTALHOSTS=$(sudo -u postgres psql -d "$DB" -t -c "SELECT COUNT(*) FROM hosts;" | xargs)
    echo "$TOTALHOSTS"
}

# Function to perform Nmap discovery scan
nmap_discovery_scan() {
    local ip_range="$1"
    echo "$(date '+%Y-%m-%d %H:%M:%S') - (OK) Starting Nmap Discovery Scan..."
    cp "$CONF/msf_default.rc" "$CONF/msf.rc"
    echo "db_nmap -Pn -v --disable-arp-ping -p 22,80,443,445 $ip_range" >> "$CONF/msf.rc"
    echo "quit -y" >> "$CONF/msf.rc"
    $MSFBIN -r "$CONF/msf.rc"
    /usr/bin/python3 "$CWD/tools/sniper.py" db_update
    echo "$(date '+%Y-%m-%d %H:%M:%S') - (OK) Completed Nmap Discovery Scan."
}

# Ensure script is run as root
if [[ $EUID -ne 0 ]]; then
    echo "$(date '+%Y-%m-%d %H:%M:%S') - (ERROR) This script must be run as root."
    exit 1
fi

# Clear previous session
clear

# Ensure required commands are available
for cmd in "$MSFBIN" "$EYEWITNESS" "psql"; do
    check_command "$cmd"
done

# Start PostgreSQL service
check_and_start_service "$SERVICE"

# Check Eyewitness installation
if [[ ! -f "$EYEWITNESS" ]]; then
    echo "$(date '+%Y-%m-%d %H:%M:%S') - (ERROR) Eyewitness not found. Please install it."
    exit 1
fi

# Import new Nmap files
import_nmap_files

# Count total hosts in the database
TOTALHOSTS=$(count_total_hosts)
echo "$(date '+%Y-%m-%d %H:%M:%S') - (OK) Total hosts in database: $TOTALHOSTS."

# Perform Nmap discovery if no hosts in the database
if [[ "$TOTALHOSTS" -eq 0 ]]; then
    read -p "(?) Enter the IP Range for QUICK host discovery [192.168.1.1-200]: " IPRANGE
    IPRANGE=${IPRANGE:-192.168.1.1-200}
    nmap_discovery_scan "$IPRANGE"
else
    echo "$(date '+%Y-%m-%d %H:%M:%S') - (OK) Database already contains $TOTALHOSTS hosts. Skipping initial discovery."
fi

# Perform Eyewitness scans
read -p "(?) Do you want to create thumbnails on ports (80,443,8000,8080,8443) with 'eyewitness' ?(y/N): " yn
case $yn in
    [Yy]*) 
        echo "$(date '+%Y-%m-%d %H:%M:%S') - (OK) Starting Eyewitness Scan..."
        cp "$CONF/msf_default.rc" "$CONF/msf.rc"
        echo "services -p 80,443,8000,8080,8443 -u -o $TEMPFILE" >> "$CONF/msf.rc"
        echo "quit -y" >> "$CONF/msf.rc"
        $MSFBIN -r "$CONF/msf.rc"
        cat "$TEMPFILE" | cut -d "\"" -f2-4 | grep -v address | sed 's/\",\"/:/g' > "${TEMPFILE}.b"
        $EYEWITNESS -f "${TEMPFILE}.b" --no-prompt --prepend-https --web -d sniper.eyewitness
        echo "$(date '+%Y-%m-%d %H:%M:%S') - (OK) Eyewitness scan complete - see sniper.eyewitness/report.html"
        rm -f "$TEMPFILE" "${TEMPFILE}.b"
        ;;
    [Nn]*|*) 
        echo "$(date '+%Y-%m-%d %H:%M:%S') - (OK) Skipping Eyewitness Scan."
        ;;
esac

# Run sniper report
read -p "(?) Do you want SNIPER to run the sniper report? (Y/n): " yn
case $yn in
    [Nn]*) 
        echo "$(date '+%Y-%m-%d %H:%M:%S') - (OK) Skipping sniper report."
        ;;
    *) 
        echo "$(date '+%Y-%m-%d %H:%M:%S') - (OK) Generating sniper report..."
        /usr/bin/python3 "$CWD/tools/sniper.py"
        ;;
esac

echo "$(date '+%Y-%m-%d %H:%M:%S') - (OK) SNIPER COMPLETE"


