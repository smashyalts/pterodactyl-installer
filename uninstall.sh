#!/bin/bash

set -e

#############################################################################
#                                                                           #
# Project 'pterodactyl-installer'                                           #
#                                                                           #
# Copyright (C) 2018 - 2021, Vilhelm Prytz, <vilhelm@prytznet.se>           #
#                                                                           #
#   This program is free software: you can redistribute it and/or modify    #
#   it under the terms of the GNU General Public License as published by    #
#   the Free Software Foundation, either version 3 of the License, or       #
#   (at your option) any later version.                                     #
#                                                                           #
#   This program is distributed in the hope that it will be useful,         #
#   but WITHOUT ANY WARRANTY; without even the implied warranty of          #
#   MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the           #
#   GNU General Public License for more details.                            #
#                                                                           #
#   You should have received a copy of the GNU General Public License       #
#   along with this program.  If not, see <https://www.gnu.org/licenses/>.  #
#                                                                           #
# https://github.com/vilhelmprytz/pterodactyl-installer/blob/master/LICENSE #
#                                                                           #
# This script is not associated with the official Pterodactyl Project.      #
# https://github.com/vilhelmprytz/pterodactyl-installer                     #
#                                                                           #
#############################################################################

######## General checks #########

# exit with error status code if user is not root
if [[ $EUID -ne 0 ]]; then
  echo "* This script must be executed with root privileges (sudo)." 1>&2
  exit 1
fi

# check for curl
if ! [ -x "$(command -v curl)" ]; then
  echo "* curl is required in order for this script to work."
  echo "* install using apt (Debian and derivatives) or yum/dnf (CentOS)"
  exit 1
fi

########## Variables ############

RM_PANEL=false
RM_WINGS=false

####### Visual functions ########

print_brake() {
  for ((n = 0; n < $1; n++)); do
    echo -n "#"
  done
  echo ""
}

output() {
  echo "* ${1}"
}

error() {
  COLOR_RED='\033[0;31m'
  COLOR_NC='\033[0m'

  echo ""
  echo -e "* ${COLOR_RED}ERROR${COLOR_NC}: $1"
  echo ""
}

warning() {
  COLOR_YELLOW='\033[1;33m'
  COLOR_NC='\033[0m'
  echo ""
  echo -e "* ${COLOR_YELLOW}WARNING${COLOR_NC}: $1"
  echo ""
}

summary() {
  print_brake 30
  output "Uninstall panel? $RM_PANEL"
  output "Uninstall wings? $RM_WINGS"
  print_brake 30
}

####### OS check funtions #######

detect_distro() {
  if [ -f /etc/os-release ]; then
    # freedesktop.org and systemd
    . /etc/os-release
    OS=$(echo "$ID" | awk '{print tolower($0)}')
    OS_VER=$VERSION_ID
  elif type lsb_release >/dev/null 2>&1; then
    # linuxbase.org
    OS=$(lsb_release -si | awk '{print tolower($0)}')
    OS_VER=$(lsb_release -sr)
  elif [ -f /etc/lsb-release ]; then
    # For some versions of Debian/Ubuntu without lsb_release command
    . /etc/lsb-release
    OS=$(echo "$DISTRIB_ID" | awk '{print tolower($0)}')
    OS_VER=$DISTRIB_RELEASE
  elif [ -f /etc/debian_version ]; then
    # Older Debian/Ubuntu/etc.
    OS="debian"
    OS_VER=$(cat /etc/debian_version)
  elif [ -f /etc/SuSe-release ]; then
    # Older SuSE/etc.
    OS="SuSE"
    OS_VER="?"
  elif [ -f /etc/redhat-release ]; then
    # Older Red Hat, CentOS, etc.
    OS="Red Hat/CentOS"
    OS_VER="?"
  else
    # Fall back to uname, e.g. "Linux <version>", also works for BSD, etc.
    OS=$(uname -s)
    OS_VER=$(uname -r)
  fi

  OS=$(echo "$OS" | awk '{print tolower($0)}')
  OS_VER_MAJOR=$(echo "$OS_VER" | cut -d. -f1)
}

check_os_comp() {
  SUPPORTED=false
  case "$OS" in
  ubuntu)
    [ "$OS_VER_MAJOR" == "18" ] && SUPPORTED=true
    [ "$OS_VER_MAJOR" == "20" ] && SUPPORTED=true
    ;;
  debian)
    [ "$OS_VER_MAJOR" == "9" ] && SUPPORTED=true
    [ "$OS_VER_MAJOR" == "10" ] && SUPPORTED=true
    ;;
  centos)
    [ "$OS_VER_MAJOR" == "7" ] && SUPPORTED=true
    [ "$OS_VER_MAJOR" == "8" ] && SUPPORTED=true
    ;;
  esac

  # exit if not supported
  if [ "$SUPPORTED" == true ]; then
    echo "* $OS $OS_VER is supported."
  else
    echo "* $OS $OS_VER is not supported"
    error "Unsupported OS"
    exit 1
  fi
}

### Main uninstallation functions ###

rm_panel_files() {
  rm -rf /var/www/pterodactyl /usr/local/bin/composer
  [ "$OS" != "centos" ] && unlink /etc/nginx/sites-enabled/pterodactyl.conf
  [ "$OS" != "centos" ] && rm -f /etc/nginx/sites-available/pterodactyl.conf
  [ "$OS" == "centos" ] && rm -f /etc/nginx/conf.d/pterodactyl.conf
}

rm_wings_files() {
  rm -rf /etc/pterodactyl /usr/local/bin/wings /var/lib/pterodactyl
}

rm_services() {
  systemctl disable --now mariadb
  systemctl disable --now pteroq
  rm -rf /etc/systemd/system/pteroq.service
  case "$OS" in
  debian | ubuntu)
    systemctl disable --now redis-server
    ;;
  centos)
    systemctl disable --now redis
    systemctl disable --now php-fpm
    rm -rf /etc/php-fpm.d/www-pterodactyl.conf
    ;;
  esac
}

rm_cron() {
  # shellcheck disable=SC2063
  crontab -l | grep -v "* * * * * php /var/www/pterodactyl/artisan schedule:run >> /dev/null 2>&1" | crontab -
}

rm_database() {
  valid_db=$(mysql -u root -p -e "SELECT schema_name FROM information_schema.schemata;" | grep -v -E -- 'schema_name|information_schema|performance_schema')
  warning "Be careful! This database will be deleted!"
  if [[ "$valid_db" == *"panel"* ]]; then
    echo -n "* Database called panel has been detected. Is it the pterodactyl database? (y/N): "
    read -r is_panel
    [[ "$is_panel" =~ [Yy] ]] && DATABASE=panel || echo "$valid_db"
  else
    echo "$valid_db"
  fi
  while [ -z "$DATABASE" ] || [[ $valid_db != *"$database_input"* ]]; do
    echo -n "* Choose the panel database(to skip type none): "
    read -r database_input
    DATABASE=$database_input
  done
  [[ "$DATABASE" != "none" ]] && mysql -u root -p -e "DROP $DATABASE"
  # Exclude usernames User and root (Hope no one uses username User)
  valid_users=$(mysql -u root -p -e "SELECT user FROM mysql.user;" | grep -v -E -- 'User|root')
  warning "Be careful! This user will be deleted!"
  if [[ "$valid_users" == *"pteroactyl"* ]]; then
    echo -n "* User called pterodactyl has been detected. Is it the pterodactyl user? (y/N): "
    read -r is_user
    [[ "$is_user" =~ [Yy] ]] && USER=pterodactyl || echo "$valid_users"
  else
    echo "$valid_users"
  fi
  while [ -z "$USER" ] || [[ $valid_users != *"$user_input"* ]]; do
    echo -n "* Choose the panel user(to skip type none): "
    read -r user_input
    USER=$user_input
  done
  [[ "$USER" != "none" ]] && mysql -u root -p -e "DROP USER '$USER'@'127.0.0.1'"
  mysql -u root -p -e "FLUSH PRIVILEGES;"
}

## MAIN FUNCTIONS ##

perform_uninstall() {
  [ "$RM_PANEL" == true ] && rm_panel_files
  [ "$RM_PANEL" == true ] && rm_services
  [ "$RM_PANEL" == true ] && rm_cron
  [ "$RM_PANEL" == true ] && rm_database
  [ "$RM_WINGS" == true ] && rm_wings_files
}

main() {
  rm_database
  exit 1
  detect_distro
  print_brake 70
  output "Pterodactyl uninstallation script"
  output
  output "Copyright (C) 2018 - 2021, Vilhelm Prytz, <vilhelm@prytznet.se>"
  output "https://github.com/vilhelmprytz/pterodactyl-installer"
  output
  output "Sponsoring/Donations: https://github.com/vilhelmprytz/pterodactyl-installer?sponsor=1"
  output "This script is not associated with the official Pterodactyl Project."
  output
  output "Running $OS version $OS_VER."
  print_brake 70
  # check_os_comp

  if [ -d "/var/www/pterodactyl" ]; then
    output "Panel installation has been detected."
    echo -e -n "* Do you want to remove panel? (y/N):"
    read -r RM_PANEL_INPUT
    [[ "$RM_PANEL_INPUT" =~ [Yy] ]] && RM_PANEL=true
  fi

  if [ -d "/etc/pterodactyl" ]; then
    output "Wings installation has been detected."
    warning "This will remove all the servers!"
    echo -e -n "* Do you want to remove wings(daemon)? (y/N):"
    read -r RM_WINGS_INPUT
    [[ "$RM_WINGS_INPUT" =~ [Yy] ]] && RM_WINGS=true
  fi

  if [ "$RM_PANEL" == false ] && [ "$RM_WINGS" == false ]; then
    error "Nothing to uninstall!"
    exit 1
  fi

  summary

  # confirm uninstallation
  echo -e -n "* Continue with uninstallation? (y/N): "
  read -r CONFIRM
  if [[ "$CONFIRM" =~ [Yy] ]]; then
    perform_uninstall
  else
    error "Installation aborted."
    exit 1
  fi
}

goodbye() {
  print_brake 62
  output "Panel uninstallation completed"
  output "Thank you for using this script."
  print_brake 62
}

main
goodbye
