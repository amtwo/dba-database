# dba-database

This is my DBA database that contains my utility scripts that I use to help manage my servers.

Some of this code was never intended to be used by anyone else--it's primarily here for myself, but if you want to use it, make sure you know exactly what it's doing before using any of this code.

Some of this code (including the installer!) assumes that the First Responder Kit (firstresponderkit.org) and Ola Hallengren's SQL Server Maintenance Solution (ola.hallengren.com) are installed in the same database as well. PowerShell script provided to pull that stuff from it's respective download location. Redistributing other people's code isn't my thing.

### Prerequisites
* **SQL Server 2016 or later.** A lot of the code uses `CREATE OR ALTER`, so older versions won't install cleanly.
* **PowerShell with the `SqlServer` module** (the installer leans on `Invoke-Sqlcmd` and `Write-SqlTableData`).
* Permission to create a database on the target instance (or a database that already exists for you to install into).

### Supported SQL Server versions:
* My goal is to support all versions of SQL Server that are currently supported by Microsoft. (2017+ as of 2026)
* Many scripts work on versions as old as SQL Server 2005, as they were written when 2005 was still a supported version. New work is not tested on older, unsupported versions. 

### To install
By default, the installer will create a database named `DBA` (if it doesn't already exist), and install all objects in that `DBA` database. You can deploy to a database named something other than `DBA` by using the `-DatabaseName` parameter on the install script. This install script assumes that you have permission to create the database, or that it already exists. 

* Clone this repo.
* Open a PowerShell prompt & navigate (ie `Set-Location`) to the `dba-database` folder you just cloned.
* Run `Get-OpenSourceScripts.ps1` to grab the latest versions of the open source/third-party projects.
* Also from dba-database folder, run `Install-LatestDbaDatabase.ps1 -InstanceName "MyInstance"`
  * By default, the installer will use `DBA` as the database name. To use a different database name, specify that using the `-DatabaseName` parameter.
  * The `-InstanceName` parameter will accept an array of server names, if you want to deploy to many servers.

_If you experience issues with the install experience, please [create an issue in GitHub](https://github.com/amtwo/dba-database/issues/new/choose)._

### Contributing
This is mostly my own toolbox, but if you want to fix something or add to it, I'm glad for the help. Start with [CONTRIBUTING.md](CONTRIBUTING.md) — it covers the coding conventions I follow and how to get a change in (short version: open an issue first, then send a PR). Be decent to each other while you're at it; the [Code of Conduct](CODE_OF_CONDUCT.md) applies.

### License
This code is licensed under the [BSD 2-Clause License](LICENSE). Use it, fork it, ship it — just keep the copyright notice around.

### Open Source Projects License information:
The bundled third-party scripts are *not* mine and keep their own licenses:
* The First Responders Kit is distributed under the [MIT License](https://github.com/BrentOzarULTD/SQL-Server-First-Responder-Kit/blob/master/LICENSE.md).
* Ola Hallengren's SQL Server Maintenance Solution is distributed under the [MIT License](https://ola.hallengren.com/license.html).
* sp_WhoIsActive is distributed under the [GNU GPL v3](https://github.com/amachanic/sp_whoisactive/blob/master/LICENSE).
* The Darling Data SQL Server Troubleshooting Scripts are distributed under the [MIT License](https://github.com/erikdarlingdata/DarlingData/blob/master/LICENSE.md).
