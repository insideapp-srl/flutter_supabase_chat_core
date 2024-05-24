#!/bin/bash

while getopts h:p:d:U: flag
do
    case "${flag}" in
        h) hostname=${OPTARG};;
        p) port=${OPTARG};;
        d) database=${OPTARG};;
        U) user=${OPTARG};;
    esac
done

psql -U $user -h $hostname -p $port -d $database -f ./sql/01_database_schema.sql
psql -U $user -h $hostname -p $port -d $database -f ./sql/02_database_trigger.sql
psql -U $user -h $hostname -p $port -d $database -f ./sql/03_database_policy.sql
psql -U $user -h $hostname -p $port -d $database -f ./sql/04_storage.sql