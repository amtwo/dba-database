<#
.SYNOPSIS
Installs or updates DBA database to the latest version
 
.DESCRIPTION
This function will create a DBA database if it does not already exist, and install the latest code. 

This depends on having the full, latest version of the full repo https://github.com/amtwo/dba-database

All dependent .sql files are itempotent:
* Table.sql scripts are written to create if not exists. Changes are maintained similarly as conditional ALTERs.
* code.sql scripst are written to create a stub, then alter with actual code.

.PARAMETER InstanceName
An array of instance names

.PARAMETER DatabaseName
By default, this will be installed in a database called "DBA". If you want to install my DBA database with
a different name, specify it here.

.PARAMETER SkipOSS
By default, this installer assumes that you've got the open source stuff in the right spot. If you don't
want to install those packages, just pass in $true for this, and it'll skip all of them.

 
.EXAMPLE
Install-LatestDbaDatabase AM2Prod
 

.NOTES
AUTHOR: Andy Mallon
DATE: 20170922
COPYRIGHT: This code is licensed as part of Andy Mallon's DBA Database. https://github.com/amtwo/dba-database/blob/master/LICENSE
©2014-2020 ● Andy Mallon ● am2.co
#>
 
[CmdletBinding()]
param (
    [Parameter(Position=0,mandatory=$true)]
        [string[]]$InstanceName,
    [Parameter(Position=1,mandatory=$false)]
        [string]$DatabaseName = 'DBA',
    [Parameter(Position=2,mandatory=$false)]
        [boolean]$SkipOSS = $false
    )

# Process servers in a loop. I could do this parallel, but doing it this way is fast enough for me.
foreach($instance in $InstanceName) {
    Write-Verbose "**************************************************************"
    Write-Verbose "                           $instance"
    Write-Verbose "**************************************************************"
    #Create the database - SQL Script contains logic to be conditional & not clobber existing database
    Write-Verbose "`n        ***Creating Database if necessary `n"
    Invoke-Sqlcmd -ServerInstance $instance -Database master -InputFile .\create-database.sql -Variable "DbName=$($DatabaseName)"

    #Create tables first
    Write-Verbose "`n        ***Creating/Updating Tables `n"
    $fileList = Get-ChildItem -Path .\tables -Recurse
    Foreach ($file in $fileList){
        Write-Verbose $file.FullName
        Invoke-Sqlcmd -ServerInstance $instance -Database $DatabaseName -InputFile $file.FullName -QueryTimeout 300
    }
    #Then views
    Write-Verbose "`n        ***Creating/Updating Views `n"
    $fileList = Get-ChildItem -Path .\views -Recurse
    Foreach ($file in $fileList){
        Write-Verbose $file.FullName
        Invoke-Sqlcmd -ServerInstance $instance -Database $DatabaseName -InputFile $file.FullName -QueryTimeout 300
    }
    #Then scalar functions
    Write-Verbose "`n        ***Creating/Updating Scalar Functions `n"
    $fileList = Get-ChildItem -Path .\functions-scalar -Recurse
    Foreach ($file in $fileList){
        Write-Verbose $file.FullName
        Invoke-Sqlcmd -ServerInstance $instance -Database $DatabaseName -InputFile $file.FullName
    }
    #Then TVFs
    Write-Verbose "`n        ***Creating/Updating Table-Valued Functions `n"
    $fileList = Get-ChildItem -Path .\functions-tvfs -Recurse
    Foreach ($file in $fileList){
        Write-Verbose $file.FullName
        Invoke-Sqlcmd -ServerInstance $instance -Database $DatabaseName -InputFile $file.FullName
    }
    #Then Procedures
    Write-Verbose "`n        ***Creating/Updating Stored Procedures `n"
    $fileList = Get-ChildItem -Path .\stored-procedures -Recurse -Filter *.sql
    Foreach ($file in $fileList){
        Write-Verbose $file.FullName
        Invoke-Sqlcmd -ServerInstance $instance -Database $DatabaseName -InputFile $file.FullName
    }
    #Skip Open Source procedures if asked
    If ($SkipOSS -eq $false){
        #Then First Responder Kit
        Write-Verbose "`n        ***Creating/Updating First Responder Kit `n"
        $fileList = Get-ChildItem -Path .\oss\firstresponderkit -Recurse -Filter *.sql
        Foreach ($file in $fileList){
            Write-Verbose $file.FullName
            Invoke-Sqlcmd -ServerInstance $instance -Database $DatabaseName -InputFile $file.FullName
        }
        #Then sp_whoisactive
        Write-Verbose "`n        ***Creating/Updating sp_WhoIsActive `n"
        $fileList = Get-ChildItem -Path .\oss\whoisactive -Recurse -Filter *.sql
        Foreach ($file in $fileList){
            Write-Verbose $file.FullName
            Invoke-Sqlcmd -ServerInstance $instance -Database master -InputFile $file.FullName
        }
        ## WOO HOO! Ola's code is idempotent now!
        Write-Verbose "`n        ***Creating/Updating Ola Hallengren Maintenance Solution `n"
        $fileList = Get-ChildItem -Path .\oss\olahallengren -Recurse -Filter *.sql
        Foreach ($file in $fileList){
            Write-Verbose $file.FullName
            Invoke-Sqlcmd -ServerInstance $instance -Database $DatabaseName -InputFile $file.FullName
        }
        ## That Erik. He's such a Darling.
        Write-Verbose "`n        ***Creating/Updating Ola Hallengren Maintenance Solution `n"
        $fileList = Get-ChildItem -Path .\oss\darlingdata -Recurse -Filter *.sql
        Foreach ($file in $fileList){
            Write-Verbose $file.FullName
            Invoke-Sqlcmd -ServerInstance $instance -Database $DatabaseName -InputFile $file.FullName
        }
    }


#That's it!
}
