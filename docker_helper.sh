#! /bin/sh

# daps2docker Docker Helper
# This script runs all the Docker-related commands, having this in a separate
# scripts makes it easier to run with root privileges

# $1 - name of original non-privileged user
# $2 - input dir
# $3 - output dir
# $4 - formats to build, comma-separated
# $5 .. $x - DC files to build

function error_exit() {
    # $1 - message string
    # $2 - error code (optional)
    echo "$1"
    [[ $2 ]] && exit $2
    exit 1
}

user=$(whoami)
user_change=1
if [[ $1 == '!!no-user-change' ]]
  then
    user_change=0
  else
    user=$1
fi
shift

outdir=$1
shift

dir=$1
shift

formats=$(echo "$1" | sed 's/,/ /g')
shift

dc_files=$*

# PAGER=cat means we avoid calling "less" here which would make it interactive
# and that is the last thing we want.
# FIXME: I am sure there is a better way to do this.
PAGER=cat systemctl status docker.service >/dev/null 2>/dev/null
service_status=$?
if [ $service_status -eq 3 ]
  then
    if [[ ! $(whoami) == 'root' ]]
      then
        echo "Docker service is not running. Give permission to start it."
        sudo systemctl start docker.service
      else
        systemctl start docker.service
    fi
  elif [ $service_status -gt 0 ]
    then
    error_exit "Issue with Docker service. Check 'systemctl status docker' yourself."
fi

docker pull susedoc/ci:openSUSE-42.3

# spawn a Daps container
docker run -d susedoc/ci:openSUSE-42.3 tail -f /dev/null

# check if spawn was successful
if [ ! $? -eq 0 ]
  then
    error_exit "Error spawning container."
fi

# first get the name of the container, then get the ID of the Daps container
docker_id=$(docker ps -aqf "ancestor=susedoc/ci:openSUSE-42.3" | head -1)
echo "Got Container ID: $docker_id"

# copy the Daps directory to the docker container
temp_dir=/daps_temp
docker exec $docker_id rm -rf $temp_dir 2>/dev/null
docker exec $docker_id mkdir $temp_dir 2>/dev/null

# only copy the stuff we want -- not sure whether that saves any time, but it
# avoids copying the build dir (which avoids confusing users if there is
# something in it already: after the build we're copying the build dir back to
# the host and then having additional stuff there is ... confusing)
for subdir in images adoc xml
  do
    [[ -d $dir/$subdir ]] && docker cp $dir/$subdir $docker_id:$temp_dir
done
for dc in $dir/DC-*
  do
    [[ -f $dc ]] && docker cp $dc $docker_id:$temp_dir
done

echo "Package versions in container:"
for dep in daps daps-devel libxslt-tools libxml2-tools xmlgraphics-fop docbook-xsl-stylesheets docbook5-xsl-stylesheets suse-xsl-stylesheets hpe-xsl-stylesheets geekodoc novdoc
  do
    rpmstring=$(docker exec $docker_id rpm -qi $dep)
    echo -n '  - '
    if [[ $(echo -e "$rpmstring" | head -1 | grep 'not installed') ]]
      then
        echo -n "$rpmstring"
      else
        echo "$rpmstring" | head -2 | awk '{print $3;}' | tr '\n' ' '
    fi
    echo ''
done

# build HTML and PDF
filelist=''
for dc_file in $dc_files
  do
    echo "Building $dc_file"
    validation=$(docker exec $docker_id daps -d $temp_dir/$dc_file validate 2>&1)
    if [[ $(echo -e "$validation" | wc -l) -gt 1 ]]
      then
        echo -e "$validation"
        error_exit "$dc_file has validation issues and cannot be built."
      else
        for format in $formats
          do
            [[ $format == 'single-html' ]] && format='html --single'
            filelist+=$(docker exec $docker_id daps -d $temp_dir/$dc_file $format)' '
        done
    fi
done

# copy the finished product back to the host
mkdir -p $outdir
docker cp $docker_id:$temp_dir/build/. $outdir
if [[ "$filelist" ]]
  then
    echo "$filelist" | tr ' ' '\n' | sed -r -e "s#^$temp_dir/build#$outdir#" >> $outdir/filelist
fi
[[ user_change -eq 1 ]] && chown -R $user $outdir

# stop the Daps container
docker stop $docker_id >/dev/null 2>/dev/null

# we won't ever use the same container again, so remove the container's files
docker rm $docker_id >/dev/null 2>/dev/null
