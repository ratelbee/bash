#!/bin/bash
#SSH config
export target_host=example.ru
export target_user=backup
export target_key_path=~/.ssh/"$target_user"_id_rsa
#PATHS
export root_path=~/backup
export backup_path=$root_path/$target_host/$(date +"%Y%m%d")/backup
export json_state_filename=.state.json
export json_state_file_path=$root_path/$target_host/$(date +"%Y%m%d")
export script_storage_path=$json_state_file_path/scripts
export backup_log_path=$json_state_file_path
#JOB
export backup_job_count=2

cat <<'EOF' > ~/.ssh/"$target_user"_id_rsa
-----BEGIN OPENSSH PRIVATE KEY-----
-----END OPENSSH PRIVATE KEY-----
EOF
chmod 0600 $target_key_path

cat <<EOF > ~/.ssh/config
Host $target_host
   HostName $target_host
   User $target_user
   IdentityFile $target_key_path
   IdentitiesOnly yes
   StrictHostKeyChecking no
   UserKnownHostsFile=/dev/null
EOF
chmod 0644 ~/.ssh/config


mkdir -p $root_path
#ls -la $root_path
mkdir -p $json_state_file_path
#ls -la $json_state_file_path
mkdir -p $script_storage_path
#ls -la $script_storage_path
mkdir -p $backup_path

exec > >(tee -a $backup_log_path/"$target_host"_backup.log)

#STEP 0
cat <<'EOF' > $script_storage_path/step_0.sh
jq -n --arg whoami $(whoami) '{"owner":$whoami,"job":0,"current_step":0}' > $json_state_file_path/$json_state_filename
EOF
#STEP 1
cat <<'EOF' > $script_storage_path/step_1_remote.sh
sudo /usr/bin/chown -R git:bacapsule /var/opt/gitlab/backups && sudo /usr/bin/chmod -R 770 /var/opt/gitlab/backups
rm -r /var/opt/gitlab/backups/* || echo 'PASS'
#1
sudo /usr/bin/tar -cf /var/opt/gitlab/backups/gitlab_backup.tar --absolute-names /etc/gitlab
#2
sudo /opt/gitlab/bin/gitlab-backup create
# SKIP=db,uploads
#3
sudo /usr/bin/chown -R git:bacapsule /var/opt/gitlab/backups && sudo /usr/bin/chmod -R 770 /var/opt/gitlab/backups
EOF
cat <<'EOF' > $script_storage_path/step_1.sh
ssh $target_user@$target_host echo "Connected to: $(cat /etc/hostname)"
ssh $target_user@$target_host 'bash -se' < $script_storage_path/step_1_remote.sh
EOF
#STEP 2
cat <<'EOF' > $script_storage_path/step_2.sh
#rsync -hav --include="*gitlab_backup.tar" --exclude='*' --remove-source-files -e "ssh  -i ${target_key_path}" $target_user@$target_host:/var/opt/gitlab/backups/* $backup_path/
rsync -hav --include="*gitlab_backup.tar" --exclude='*' --remove-source-files $target_user@$target_host:/var/opt/gitlab/backups/* $backup_path/
EOF
#STATE INIT
cat <<'EOF' > $script_storage_path/state_init.sh
cat $json_state_file_path/$json_state_filename | jq '.job = 0' | jq --arg step_id $step_id '.current_step = ($step_id | tonumber)' | jq --arg step_id $step_id '.'step_${step_id}' = 0'  > $json_state_file_path/tmp && mv $json_state_file_path/tmp $json_state_file_path/$json_state_filename
EOF
#STATE SUCCESS
cat <<'EOF' > $script_storage_path/state_success.sh
cat $json_state_file_path/$json_state_filename | jq --arg step_id $step_id '.'step_${step_id}' = 1'  > $json_state_file_path/tmp && mv $json_state_file_path/tmp $json_state_file_path/$json_state_filename
EOF
#STATE ERROR EXIT
cat <<'EOF' > $script_storage_path/state_error_exit.sh
cat $json_state_file_path/$json_state_filename | jq --arg step_id $step_id '.'step_${step_id}' = 2' | jq '.job = 2'  > $json_state_file_path/tmp && mv $json_state_file_path/tmp $json_state_file_path/$json_state_filename
EOF
#STATE ERROR SKIP !!! NOT READY
cat <<'EOF' > $script_storage_path/state_error_skip.sh
cat $json_state_file_path/$json_state_filename | jq --arg step_id $step_id '.'step_${step_id}' = 2' | jq --arg step_id $step_id '.skiped_jobs = [${step_id}]'> $json_state_file_path/tmp && mv $json_state_file_path/tmp $json_state_file_path/$json_state_filename
EOF
chmod +x $script_storage_path/*
#STATE JOB COMPLETE
cat <<'EOF' > $script_storage_path/state_job_complete.sh
cat $json_state_file_path/$json_state_filename | jq '.job = 1'  > $json_state_file_path/tmp && mv $json_state_file_path/tmp $json_state_file_path/$json_state_filename
EOF
#STATE JOB ERROR
cat <<'EOF' > $script_storage_path/state_job_error.sh
cat $json_state_file_path/$json_state_filename | jq '.job = 2'  > $json_state_file_path/tmp && mv $json_state_file_path/tmp $json_state_file_path/$json_state_filename
exit
EOF


#TRAP
int_handler()
{
    echo "Job Interrupted on $(date)" >> $backup_log_path/"$target_host"_backup.log
    # Kill the parent process of the script.
    $script_storage_path/state_error_exit.sh
    kill $PPID
    exit 1
}
trap 'int_handler' INT

#LOGIC
if [ ! -f $json_state_file_path/$json_state_filename ]; then
  export step_id=0
elif [[ $(jq .job $json_state_file_path/$json_state_filename) == 1 ]]; then
    echo 'Job done earlier'
    exit
elif [[ $(jq .job $json_state_file_path/$json_state_filename) == 2 && $(jq .step_$(jq .current_step $json_state_file_path/$json_state_filename) $json_state_file_path/$json_state_filename) == 2 ]]; then
    export step_id=$(jq .current_step $json_state_file_path/$json_state_filename)
else
    export step_id=0
fi
#MAIN
echo "Job run $(date)"
for ((i=$step_id; i <= $backup_job_count; i++))
  do
    step_id=$i
    if [[ $step_id != 0 ]]; then $script_storage_path/state_init.sh; fi
    echo "Step ${step_id}:"
    echo "Script for execution: ${script_storage_path}/step_${step_id}.sh"
    if $script_storage_path/step_"$step_id".sh
    then
        $script_storage_path/state_success.sh
    else
	$script_storage_path/state_error_exit.sh
	exit
    fi
  done
$script_storage_path/state_job_complete.sh
