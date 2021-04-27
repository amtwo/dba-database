# dba-database

This is my DBA database that contains my utility scripts that I use to help manage my servers.

Some of this code was never intended to be used by anyone else--it's primarily here for myself, but if you want to use it, make sure you know exactly what it's doing before using any of this code.

Some of this code (including the installer!) assumes that the First Responder Kit (firstresponderkit.org) and Ola Hallengren's SQL Server Maintenance Solution (ola.hallengren.com) are installed in the same database as well. PowerShell script provided to pull that stuff from it's respective download location. Redistributing other people's code isn't my thing.

### To install
* Clone this repo.
* From the dba-database folder, run `Get-OpenSourceScripts.ps1` to grab the latest versions of the open source/third-party projects.
* Also from dba-database folder, run `Install-LatestDbaDatabase.ps1 -InstanceName "MyInstance"`
* You can pass in an array of server names to `Install-LatestDbaDatabase` if you want to deploy to many servers.


### Open Source Projects License information:
* The First Responders Kit is distributed under the [MIT License](https://github.com/BrentOzarULTD/SQL-Server-First-Responder-Kit/blob/master/LICENSE.md).
* Ola Hallengren's SQL Server Maintenance Solution is distributed under the [MIT License](https://ola.hallengren.com/license.html).
* sp_WhoIsActive is distributed under the [GNU GPL v3](https://github.com/amachanic/sp_whoisactive/blob/master/LICENSE).
* The Darling Data SQL Server Troubleshooting Scripts are distributed under the [MIT License](https://github.com/erikdarlingdata/DarlingData/blob/master/LICENSE.md).