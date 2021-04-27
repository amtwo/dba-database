# Output directory
$dir = Get-Location

# Ola Hallengren's maintenance scripts
New-Item -Path "$($dir)\oss\olahallengren" -ItemType Directory -Force |Out-Null
$url = "https://raw.githubusercontent.com/olahallengren/sql-server-maintenance-solution/master"
Invoke-WebRequest -Uri "$($url)/CommandExecute.sql" -OutFile "$($dir)\oss\olahallengren\CommandExecute.sql"
Invoke-WebRequest -Uri "$($url)/CommandLog.sql" -OutFile "$($dir)\oss\olahallengren\CommandLog.sql"
Invoke-WebRequest -Uri "$($url)/DatabaseBackup.sql" -OutFile "$($dir)\oss\olahallengren\DatabaseBackup.sql"
Invoke-WebRequest -Uri "$($url)/DatabaseIntegrityCheck.sql" -OutFile "$($dir)\oss\olahallengren\DatabaseIntegrityCheck.sql"
Invoke-WebRequest -Uri "$($url)/IndexOptimize.sql" -OutFile "$($dir)\oss\olahallengren\IndexOptimize.sql"

# First Responder Kit
New-Item -Path "$($dir)\oss\firstresponderkit" -ItemType Directory -Force |Out-Null
$url = "https://raw.githubusercontent.com/BrentOzarULTD/SQL-Server-First-Responder-Kit/master"
Invoke-WebRequest -Uri "$($url)/sp_Blitz.sql" -OutFile "$($dir)\oss\firstresponderkit\sp_Blitz.sql"
Invoke-WebRequest -Uri "$($url)/sp_BlitzBackups.sql" -OutFile "$($dir)\oss\firstresponderkit\sp_BlitzBackups.sql"
Invoke-WebRequest -Uri "$($url)/sp_BlitzCache.sql" -OutFile "$($dir)\oss\firstresponderkit\sp_BlitzCache.sql"
Invoke-WebRequest -Uri "$($url)/sp_BlitzFirst.sql" -OutFile "$($dir)\oss\firstresponderkit\sp_BlitzFirst.sql"
Invoke-WebRequest -Uri "$($url)/sp_BlitzIndex.sql" -OutFile "$($dir)\oss\firstresponderkit\sp_BlitzIndex.sql"
Invoke-WebRequest -Uri "$($url)/sp_BlitzLock.sql" -OutFile "$($dir)\oss\firstresponderkit\sp_BlitzLock.sql"
#This throws errors when I try to deploy it to <2016 servers. Pulling it for now--will revisit later.
#Invoke-WebRequest -Uri "$($url)/sp_BlitzQueryStore.sql" -OutFile "$($dir)\oss\firstresponderkit\sp_BlitzQueryStore.sql"
Invoke-WebRequest -Uri "$($url)/sp_BlitzWho.sql" -OutFile "$($dir)\oss\firstresponderkit\sp_BlitzWho.sql"
Invoke-WebRequest -Uri "$($url)/sp_ineachdb.sql" -OutFile "$($dir)\oss\firstresponderkit\sp_ineachdb.sql"

# sp_WhoIsActive
New-Item -Path "$($dir)\oss\whoisactive" -ItemType Directory -Force |Out-Null
$url = "https://raw.githubusercontent.com/amachanic/sp_whoisactive/master"
Invoke-WebRequest -Uri "$($url)/who_is_active.sql" -OutFile "$($dir)\oss\whoisactive\who_is_active.sql"


# Darling Data Troubleshooting scripts
New-Item -Path "$($dir)\oss\darlingdata" -ItemType Directory -Force |Out-Null
$url = "https://raw.githubusercontent.com/erikdarlingdata/DarlingData/master"
Invoke-WebRequest -Uri "$($url)/sp_PressureDetector/sp_PressureDetector.sql" -OutFile "$($dir)\oss\darlingdata\sp_PressureDetector.sql"
Invoke-WebRequest -Uri "$($url)/sp_HumanEvents/sp_HumanEvents.sql" -OutFile "$($dir)\oss\darlingdata\sp_HumanEvents.sql"

