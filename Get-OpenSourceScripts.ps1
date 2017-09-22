# Output directory
$dir = Get-Location

# Ola Hallengren's maintenance scripts
New-Item -Path "$($dir)\oss\olahallengren" -ItemType Directory -Force |Out-Null
$url = "https://ola.hallengren.com/scripts"
Invoke-WebRequest -Uri "$($url)/CommandExecute.sql" -OutFile "$($dir)\oss\olahallengren\CommandExecute.sql"
Invoke-WebRequest -Uri "$($url)/CommandLog.sql" -OutFile "$($dir)\oss\olahallengren\CommandLog.sql"
Invoke-WebRequest -Uri "$($url)/DatabaseBackup.sql" -OutFile "$($dir)\oss\olahallengren\DatabaseBackup.sql"
Invoke-WebRequest -Uri "$($url)/DatabaseIntegrityCheck.sql" -OutFile "$($dir)\oss\olahallengren\DatabaseIntegrityCheck.sql"
Invoke-WebRequest -Uri "$($url)/IndexOptimize.sql" -OutFile "$($dir)\oss\olahallengren\IndexOptimize.sql"

# First Responder Kit
New-Item -Path "$($dir)\oss\firstresponderkit" -ItemType Directory -Force |Out-Null
$url = "https://raw.githubusercontent.com/BrentOzarULTD/SQL-Server-First-Responder-Kit/master"
Invoke-WebRequest -Uri "$($url)/sp_Blitz.sql" -OutFile "$($dir)\oss\firstresponderkit\sp_Blitz.sql"
Invoke-WebRequest -Uri "$($url)/sp_BlitzCache.sql" -OutFile "$($dir)\oss\firstresponderkit\sp_BlitzCache.sql"
Invoke-WebRequest -Uri "$($url)/sp_BlitzFirst.sql" -OutFile "$($dir)\oss\firstresponderkit\sp_BlitzFirst.sql"
Invoke-WebRequest -Uri "$($url)/sp_BlitzIndex.sql" -OutFile "$($dir)\oss\firstresponderkit\sp_BlitzIndex.sql"
Invoke-WebRequest -Uri "$($url)/sp_BlitzWho.sql" -OutFile "$($dir)\oss\firstresponderkit\sp_BlitzWho.sql"
Invoke-WebRequest -Uri "$($url)/sp_foreachdb.sql" -OutFile "$($dir)\oss\firstresponderkit\sp_foreachdb.sql"

# sp_WhoIsActive
New-Item -Path "$($dir)\oss\whoisactive" -ItemType Directory -Force |Out-Null
# Adam packages this as a versioned zip, so need to update the URL every time
$url = "http://whoisactive.com/downloads/who_is_active_v11_17.zip"
Invoke-WebRequest -Uri $url -OutFile "$($dir)\oss\whoisactive\sp_WhoIsActive.zip"
# yuk, since the .sql file is versioned, delete the old ones before unzipping
Remove-Item -Path "$($dir)\oss\whoisactive\*.*" -Exclude "sp_WhoIsActive.zip"
Expand-Archive -Path "$($dir)\oss\whoisactive\sp_WhoIsActive.zip" -DestinationPath "$($dir)\oss\WhoIsActive" -Force