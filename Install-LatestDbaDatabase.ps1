<#
.SYNOPSIS
Installs or updates DBA database to the latest version
 
.DESCRIPTION
This function will create a DBA database if it does not already exist, and install the latest code. 

This depends on having the full, latest version of the full repo https://github.com/amtwo/dba-database

All dependent .sql files are itempotent:
* Table.sql scripts are written to create if not exists. Changes are maintained similarly as conditional ALTERs.
* code.sql scripst are written to create a stub, then alter with actual code.

.PARAMETER instanceName
An array of instance names
 
.EXAMPLE
Install-LatestDbaDatabase AM2Prod
 

.NOTES
AUTHOR: Andy Mallon
DATE: 20170922
#>
 
[CmdletBinding()]
param ([string[]]$instanceName)

# Process servers in a loop. I could do this parallel, but doing it this way is fast enough for me.
foreach($instance in $instanceName) {
    Write-Verbose "**************************************************************"
    Write-Verbose "                           $instance"
    Write-Verbose "**************************************************************"
    #Create the database - SQL Script contains logic to be conditional & not clobber existing database
    Write-Verbose "`n        ***Creating Database if necessary `n"
    Invoke-Sqlcmd -ServerInstance $instance -Database master -InputFile .\create-database.sql

    #Create tables first
    Write-Verbose "`n        ***Creating/Updating Tables `n"
    $fileList = Get-ChildItem -Path .\tables -Recurse
    Foreach ($file in $fileList){
        Write-Verbose $file.FullName
        Invoke-Sqlcmd -ServerInstance $instance -Database DBA -InputFile $file.FullName
    }
    #Then scalar functions
    Write-Verbose "`n        ***Creating/Updating Scalar Functions `n"
    $fileList = Get-ChildItem -Path .\functions-scalar -Recurse
    Foreach ($file in $fileList){
        Write-Verbose $file.FullName
        Invoke-Sqlcmd -ServerInstance $instance -Database DBA -InputFile $file.FullName
    }
    #Then TVFs
    Write-Verbose "`n        ***Creating/Updating Table-Valued Functions `n"
    $fileList = Get-ChildItem -Path .\functions-tvfs -Recurse
    Foreach ($file in $fileList){
        Write-Verbose $file.FullName
        Invoke-Sqlcmd -ServerInstance $instance -Database DBA -InputFile $file.FullName
    }
    #Then Procedures
    Write-Verbose "`n        ***Creating/Updating Stored Procedures `n"
    $fileList = Get-ChildItem -Path .\stored-procedures -Recurse -Filter *.sql
    Foreach ($file in $fileList){
        Write-Verbose $file.FullName
        Invoke-Sqlcmd -ServerInstance $instance -Database DBA -InputFile $file.FullName
    }
    #Then First Responder Kit
    Write-Verbose "`n        ***Creating/Updating First Responder Kit `n"
    $fileList = Get-ChildItem -Path .\oss\firstresponderkit -Recurse -Filter *.sql
    Foreach ($file in $fileList){
        Write-Verbose $file.FullName
        Invoke-Sqlcmd -ServerInstance $instance -Database DBA -InputFile $file.FullName
    }
     #Then sp_whoisactive
     Write-Verbose "`n        ***Creating/Updating sp_WhoIsActive `n"
     $fileList = Get-ChildItem -Path .\oss\whoisactive -Recurse -Filter *.sql
     Foreach ($file in $fileList){
         Write-Verbose $file.FullName
         Invoke-Sqlcmd -ServerInstance $instance -Database DBA -InputFile $file.FullName
     }
     # Ola's code isn't idempotent, so I can't automatically install them the same way. Balls.

#That's it!
}