#!/bin/bash
export target_host=example.com
export target_user=backup
export target_key_path="~/.ssh/backup"

export root_path=~/backup
export backup_path=$root_path/$target_host/$(date +"%Y%m%d")
export json_state_filename=.state.json
export json_state_file_path=$root_path/$target_host/$(date +"%Y%m%d")
export script_storage_path=$json_state_file_path/scripts

export backup_job_count=2
cat <<'EOF' > ~/.ssh/$target_user_id_rsa
-----BEGIN OPENSSH PRIVATE KEY-----
-----END OPENSSH PRIVATE KEY-----
EOF
chmod 0600 ~/.ssh/$target_user_id_rsa

cat <<'EOF' > ~/.ssh/config
Host *
   StrictHostKeyChecking no
   UserKnownHostsFile=/dev/null
EOF
chmod 0644 ~/.ssh/config


mkdir -p $root_path
mkdir -p $json_state_file_path
mkdir -p $script_storage_path

exec > >(tee -a $json_state_file_path/backup.log)

#STEP 1
cat <<EOF > $script_storage_path/step_1_remote.sh
sudo /usr/bin/chown -R git:$target_user /var/opt/gitlab/backups && sudo /usr/bin/chmod -R 770 /var/opt/gitlab/backups
rm -r /var/opt/gitlab/backups/*
#1
sudo /usr/bin/tar -cf /var/opt/gitlab/backups/gitlab_backup.tar --absolute-names /etc/gitlab
#2
sudo /opt/gitlab/bin/gitlab-backup create
#3
sudo /usr/bin/chown -R git:$target_user /var/opt/gitlab/backups && sudo /usr/bin/chmod -R 770 /var/opt/gitlab/backups
EOF
cat <<'EOF' > $script_storage_path/step_1.sh
ssh -i $target_key_path $target_user@$target_host 'bash -s' < $script_storage_path/step_1_remote.sh
EOF
#STEP 2
cat <<'EOF' > $script_storage_path/step_2.sh
rsync -havP --include="*gitlab_backup.tar" --exclude='*' --remove-source-files -e "ssh  -i ${target_key_path}" $target_user@$target_host:/var/opt/gitlab/backups/* $backup_path/
EOF
#STATE INIT
cat <<'EOF' > $script_storage_path/state_init.sh
cat $json_state_file_path/$json_state_filename | jq --arg step_id $step_id '.current_step = ($step_id | tonumber)' | jq --arg step_id $step_id '.'step_${step_id}' = 0'  > $json_state_file_path/tmp && mv $json_state_file_path/tmp $json_state_file_path/$json_state_filename
EOF
#STATE SUCCESS
cat <<'EOF' > $script_storage_path/state_success.sh
cat $json_state_file_path/$json_state_filename | jq --arg step_id $step_id '.'step_${step_id}' = 1'  > $json_state_file_path/tmp && mv $json_state_file_path/tmp $json_state_file_path/$json_state_filename
EOF
#STATE ERROR
cat <<'EOF' > $script_storage_path/state_error.sh
cat $json_state_file_path/$json_state_filename | jq --arg step_id $step_id '.'step_${step_id}' = 2'  > $json_state_file_path/tmp && mv $json_state_file_path/tmp $json_state_file_path/$json_state_filename
EOF
chmod +x $script_storage_path/*

#BACKUP
if [[ $(jq .job $json_state_file_path/$json_state_filename) == 1 ]]; then
  echo 'Job executed'
  exit
#or file not exist
elif [[ $(jq .job $json_state_file_path/$json_state_filename) == 0 ]]; then
  echo "Job run $(date)"
  echo "{ \"job\": 0, \"current_step\": 0, \"owner\": \"$(whoami)\" }" > $json_state_file_path/$json_state_filename
  export stat_id=0
  for ((i=1; i <= $backup_job_count; i++))
  do
    export step_id=$i
    $script_storage_path/state_init.sh
    $script_storage_path/step_$step_id.sh && $script_storage_path/state_success.sh || $script_storage_path/state_error.sh exit
  done

elif [[ $(jq .job $json_state_file_path/$json_state_filename) == 2 && $(jq .step_$(jq .current_step $json_state_file_path/$json_state_filename) $json_state_file_path/$json_state_filename) == 2 ]]; then
  echo "Job run $(date)"

  for ((i=$(jq .current_step $json_state_file_path/$json_state_filename); i <= $backup_job_count; i++))
  do
    export step_id=$i
    $script_storage_path/state_init.sh
    $script_storage_path/step_$step_id.sh && $script_storage_path/state_success.sh || $script_storage_path/state_error.sh exit
  done
else
  echo "Job run $(date)"
  echo "{ \"job\": 0, \"current_step\": 0, \"owner\": \"$(whoami)\" }" > $json_state_file_path/$json_state_filename
  export stat_id=0
  for ((i=1; i <= $backup_job_count; i++))
  do
    export step_id=$i
    $script_storage_path/state_init.sh
    $script_storage_path/step_$step_id.sh && $script_storage_path/state_success.sh || $script_storage_path/state_error.sh exit
  done
fi
