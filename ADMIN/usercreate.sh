#!/bin/bash

# Ensure script is run as root
if [ "$EUID" -ne 0 ]; then
  echo "Please run this script as root or with sudo."
  exit 1
fi

# Detect admin group
if getent group sudo >/dev/null; then
  ADMIN_GROUP="sudo"
elif getent group wheel >/dev/null; then
  ADMIN_GROUP="wheel"
else
  ADMIN_GROUP=""
fi

if [ -n "$ADMIN_GROUP" ]; then
  echo "Detected admin group: $ADMIN_GROUP"
else
  echo "No sudo/wheel group detected. Admin assignment will be skipped."
fi

# Ask how many users to create
read -p "How many users do you want to create? " user_count

if ! [[ "$user_count" =~ ^[0-9]+$ ]] || [ "$user_count" -lt 1 ]; then
  echo "Invalid number."
  exit 1
fi

# Loop through users
for (( i=1; i<=user_count; i++ ))
do
  echo ""

  # Prompt for username with validation
  while true; do
    read -p "Enter username for user $i: " username

    if [[ ! "$username" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]]; then
      echo "Invalid username '$username'."
      echo "Usernames must start with a letter or underscore, contain only"
      echo "lowercase letters, digits, hyphens, or underscores, and be at most 32 characters."
      continue
    fi

    if id "$username" &>/dev/null; then
      echo "User '$username' already exists. Please choose a different username."
      continue
    fi

    break
  done

  # Create user with home directory and bash shell
  if ! useradd -m -s /bin/bash "$username"; then
    echo "Failed to create user '$username'. Skipping..."
    continue
  fi

  echo "User '$username' created."

  # Ask about admin privileges if group exists
  if [ -n "$ADMIN_GROUP" ]; then
    read -p "Add '$username' to $ADMIN_GROUP group? (y/n): " addadmin
    if [[ "$addadmin" =~ ^[Yy]$ ]]; then
      usermod -aG "$ADMIN_GROUP" "$username"
      echo "'$username' added to $ADMIN_GROUP group."
    fi
  fi

  # Password options
  echo "Password options for '$username':"
  echo "1) Set custom password now"
  echo "2) Skip (account will be locked until a password is set manually)"

  read -p "Choose option (1 or 2): " pass_option

  case $pass_option in
    1)
      # Retry loop in case passwd rejects a weak password
      while true; do
        if passwd "$username"; then
          break
        else
          read -p "Password was not set. Try again? (y/n): " retry
          if [[ ! "$retry" =~ ^[Yy]$ ]]; then
            echo "Skipping password for '$username'. Account will be locked."
            break
          fi
        fi
      done
      ;;
    2)
      echo "No password set. '$username' will be locked until a password is assigned."
      ;;
    *)
      echo "Invalid option. No password set. '$username' will be locked until a password is assigned."
      ;;
  esac

  # Ask whether to force password change on first login
  read -p "Force '$username' to change password on first login? (y/n): " forcechange
  if [[ "$forcechange" =~ ^[Yy]$ ]]; then
    chage -d 0 "$username"
    echo "Password change will be required on first login for '$username'."
  fi

done

echo ""
echo "All tasks completed."