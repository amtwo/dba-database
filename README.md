# dba-database

This is my DBA database that contains my utility scripts that I use to help manage my servers.

Some of this code was never intended to be used by anyone else--it's primarily here for myself, but if you want to use it, make sure you know exactly what it's doing before using any of this code.

Some of this code (including the installer!) assumes that the First Responder Kit (firstresponderkit.org) and Ola Hallengren's SQL Server Maintenance Solution (ola.hallengren.com) are installed in the same database as well. PowerShell script provided to pull that stuff from it's respective download location. Redistributing other people's code isn't my thing.

### To install
By default, the installer will create a database named `DBA` (if it doesn't already exist), and install all objects in that `DBA` database. You can deploy to a database named something other than `DBA` by using the `-DatabaseName` parameter on the install script. This install script assumes that you have permission to create the database, or that it already exists. 

* Clone this repo.
* Open a PowerShell prompt & navigate (ie `Set-Location`) to the `dba-database` folder you just cloned.
* Run `Get-OpenSourceScripts.ps1` to grab the latest versions of the open source/third-party projects.
* Also from dba-database folder, run `Install-LatestDbaDatabase.ps1 -InstanceName "MyInstance"`
  * By default, the installer will use `DBA` as the database name. To use a different database name, specify that using the `-DatabaseName` paramater.
  * The `-InstanceName` parameter will accept an array of server names, if you want to deploy to many servers.

_If you experience issues with the install experience, please [create an issue in GitHub](https://github.com/amtwo/dba-database/issues/new/choose)._

### Open Source Projects License information:
* The First Responders Kit is distributed under the [MIT License](https://github.com/BrentOzarULTD/SQL-Server-First-Responder-Kit/blob/master/LICENSE.md).
* Ola Hallengren's SQL Server Maintenance Solution is distributed under the [MIT License](https://ola.hallengren.com/license.html).
* sp_WhoIsActive is distributed under the [GNU GPL v3](https://github.com/amachanic/sp_whoisactive/blob/master/LICENSE).
* The Darling Data SQL Server Troubleshooting Scripts are distributed under the [MIT License](https://github.com/erikdarlingdata/DarlingData/blob/master/LICENSE.md).
