#
# Usage: CheckmarxPoCSetup.ps1 -zipPass xxxxxxxxxxxxxxxxxx
 
param (
  [Parameter(Mandatory=$true)][string]$zipPass
)

function log([string]$output) {
  Add-Content -Path $global:logfile -Value $output
}

function GetHardwareInfo() {
  $output = (systeminfo | Select-String 'Total Physical Memory:').ToString().Split(':')[1].Trim()
  log "RAM = $output"

  $output = (Get-CimInstance Win32_ComputerSystem).NumberOfLogicalProcessors
  log "CORES = $output"
}

function InstallChocolatey() {
  Set-ExecutionPolicy Bypass -Scope Process -Force; iex ((New-Object System.Net.WebClient).DownloadString('https://chocolatey.org/install.ps1')) *>$null

  log("Installed Chocolatey")
}

function InstallChocolateyPackages
{
  Param(
    [ValidateNotNullOrEmpty()][string] $packagesList
  )

  $separator = @(",")
  $splitOption = [System.StringSplitOptions]::RemoveEmptyEntries
  $packages = $packagesList.Trim().Split($separator, $splitOption)

    if (0 -eq $packages.Count)
    {
      log 'No packages were specified. Exiting.'
      return        
    }

    foreach ($package in $packages)
    {
      $package = $package.Trim()

      log "Installing package: $package ..."

      # using --force will crash some package installs
      choco install $package --yes --acceptlicense --verbose --allow-empty-checksums | Out-Null  
      if (-not $?) {
        $errMsg = "Installation failed for $package : Please see the chocolatey logs in %ALLUSERSPROFILE%\chocolatey\logs folder for details."
        #throw $errMsg 
	log $errMsg
      } else {
        log "Installed $package"
      }      
    }
}

function UpdateJenkinsServer() {
  # Set the port Jenkins uses
  $Config = Get-Content `
    -Path "${ENV:ProgramFiles(x86)}\Jenkins\Jenkins.xml"
  $NewConfig = $Config `
    -replace '--httpPort=[0-9]*\s',"--httpPort=8090 "
  Set-Content `
    -Path "${ENV:ProgramFiles(x86)}\Jenkins\Jenkins.xml" `
    -Value $NewConfig `
    -Force
  Restart-Service `
    -Name Jenkins
}

function InstallCppRedist(){
  log "Installing CPP Redist..."

  $pwd = Get-Location
  Set-Location -Path 'third_party\C++_Redist' *>> $global:logfile

  $cppInstall = ".\vcredist_x64.exe /passive /norestart"
  $cppInstallOut = cmd.exe /c $cppInstall *>> $global:logfile
  $cppInstallOut

  Set-Location -Path $pwd *>> $global:logfile

  log "...Finished"
}

function InstallDotNet(){
  log "Installing DotNet..."
  
  $pwd = Get-Location
  Set-Location -Path 'third_party\.NET Core - Windows Server Hosting' *>> $global:logfile

  $dotNetInstall = ".\dotnet-hosting-2.1.14-win.exe /install /quiet /norestart"
  $dotNetInstallOut = cmd.exe /c $dotNetInstall *>> $global:logfile
  $dotNetInstallOut

  Set-Location -Path $pwd *>> $global:logfile

  log "...Finished"
}

function InstallIIS(){
  # Get-WindowsOptionalFeature -Online | where FeatureName -like 'IIS-*'
  log "Installing IIS Components..."  
  if ((Get-WindowsFeature Web-Server).InstallState -ne 'Installed') {
    Write-Output "Installing IIS features..."
    Install-WindowsFeature -name Web-Server -IncludeManagementTools
    Add-WindowsFeature Web-Http-Redirect
  }
  log "...Finished Installing IIS Components"
}

function DownloadZip {
  Param(
    [string] $url,
    [string] $zipfile
  )

  if ($url -and $zipfile) {
    log "downloading $url $zipfile"

    $file = $(get-location).Path + "\" + $zipfile

    log $file

    #download file
    try {
      $wc = (New-Object System.Net.WebClient).DownloadFile($url, $file)
      log "[PASS] Downloaded $zipfile"
    } catch [System.Net.WebException],[System.IO.IOException]{
      log "[ERROR] failed to download $zipfile" 	
    }
  } else {
    log "invalid parameters"
  }
}

function InstallCheckmarx(){	
  log "Installing Checkmarx using Windows Based DB Auth"
	
  $CxInstall = 'CxSetup.exe /install /quiet ACCEPT_EULA=Y SQLAUTH=1 BI=1 ENGINE=1 MANAGER=1 WEB=1 AUDIT=1 INSTALLSHORTCUTS=1 CX_JAVA_HOME="C:\Program Files\Java\jre1.8.0_241"'

  $CxInstallOut = cmd.exe /c $CxInstall *>> $global:logfile
  
  log "...Finished installing base Checkmarx"
}

function osaHealth() {
  $response = Invoke-WebRequest -METHOD POST -URI https://service-sca.checkmarx.net/health

  log "POST to https://service-sca.checkmarx.net/health: $response"

  $mavenVersion = mvn -v
  log "[MAVEN] $mavenVersion `n"

  $gradleVersion = gradle -v
  log "[GRADLE] $gradleVersion `n"

  $dotnetVersion = dotnet --info
  log "[DOTNET] $dotnetVersion `n"
	
  $npmVersion = npm -v
  log "[NPM] $npmVersion `n"

  $pipVersion = pip -V
  log "[PIP] $pipVersion `n"
  
  $sbtVersion = sbt --version
  log "[SBT] $sbtVersion `n"
}

function setEnvVars() {
  [System.Environment]::SetEnvironmentVariable("JAVA_HOME", "C:\Program Files\Java\jdk1.8.0_211", [System.EnvironmentVariableTarget]::User)
  [System.Environment]::SetEnvironmentVariable("MAVEN_HOME", "C:\ProgramData\chocolatey\lib\maven\apache-maven-3.6.3", [System.EnvironmentVariableTarget]::User)

  [Environment]::SetEnvironmentVariable("Path", [Environment]::GetEnvironmentVariable('Path', [EnvironmentVariableTarget]::User) + "$($Env:MAVEN_HOME)\bin", [EnvironmentVariableTarget]::User)
}

function extract () {
  if (-not (test-path "$env:ProgramFiles\7-Zip\7z.exe")) {
    throw "$env:ProgramFiles\7-Zip\7z.exe needed"
  } else {
    log "7Zip found, pass= $zipPass"
    $env:Path += ";C:\Program Files\7-Zip\"
		
    $zipFile = "CxSAST_Release_Setup.zip"
		
    7z.exe "t" $zipFile "-p$zipPass" >$null 2>&1
    if (-Not $?)
      {
      Write-Host $zipPass "is not the password."
      Remove-Item $zipFile *>> $global:logfile
      return
     } else {
       log "zip password matches"
       $zipoutput = 7z.exe x "-p$zipPass" -oinstaller\ $zipFile
       log $zipoutput
			
       Remove-Item $zipFile *>> $global:logfile
     }
   }
}

function updateSettingsXml () {
  $filetxt = [IO.File]::ReadAllText("C:\ProgramData\chocolatey\lib\maven\apache-maven-3.6.3\conf\settings.xml")
	
  $filetxt = ($filetxt -replace "(?ms)^\s+<localRepository>/path/to/local/repo</localRepository>.*?-->", "-->`n<localRepository>C:/M2</localRepository>")
	
  Set-Content -Path "C:\ProgramData\chocolatey\lib\maven\apache-maven-3.6.3\conf\settings.xml" -Value $filetxt
	
  log "Updated settings.xml to have path to C:\m2"
}

## main

$global:logfile = $(get-location).Path + "\checkmarx_install_info.txt"

log "------------------ Beginning of Installation ------------------"

if ( Test-Path -Path 'installer'  ) { Remove-Item 'installer' -Recurse -Force | Out-Null }
if ( Test-Path -Path 'plugins'  ) { Remove-Item 'plugins' -Recurse -Force | Out-Null }
if ( Test-Path -Path 'CxSAST_Release_Setup.zip'  ) { Remove-Item 'CxSAST_Release_Setup.zip' -Force | Out-Null }

Write-Host "Get Computer Specs"

GetHardwareInfo

InstallChocolatey

Write-Host "Installing CxServer prerequisites..."

if (Test-Path "HKLM:\Software\Microsoft\Microsoft SQL Server\Instance Names\SQL") {
  log "SQL already installed"
} else {
  cinst -y sql-server-express --ia "/TCPENABLED=1" | Out-Null 
}

$packagesList = "vcredist140,git,dotnetcore-windowshosting"
InstallChocolateyPackages($packagesList)

Write-Host "Installing JDK8 and package managers..."
$packagesList = "jdk8,jre8,maven,nodejs-lts,dotnetcore-sdk,nuget.commandline,gradle,python3,sbt"
InstallChocolateyPackages($packagesList)

Write-Host "Installing utils (optional but recommended)..."
$packagesList = "7zip,NotepadPlusPlus,jenkins,GoogleChrome,ssms"
InstallChocolateyPackages($packagesList)

UpdateJenkinsServer

Write-Host "Downloading Checkmarx & Checkmarx Plugins..."

New-Item -ItemType Directory -Force -Path plugins *>> $global:logfile

DownloadZip "https://download.checkmarx.com/9.0.0/CxSAST.900.Release.Setup-GitMigration_9.0.0.40085.zip" "CxSAST_Release_Setup.zip"
DownloadZip "https://download.checkmarx.com/9.0.0/Plugins/TeamCity-9.00.1.zip" "plugins\TeamCity-9.00.1.zip"
DownloadZip "https://download.checkmarx.com/9.0.0/Plugins/CxViewer-IntelliJ-9.00.1.zip" "plugins\CxViewer-IntelliJ-9.00.1.zip"
DownloadZip "https://download.checkmarx.com/9.0.0/Plugins/Jenkins_9.00.1.zip" "plugins\Jenkins_9.00.1.zip"
DownloadZip "https://download.checkmarx.com/9.0.0/Plugins/Bamboo-9.0.1.zip" "plugins\Bamboo-9.0.1.zip"
DownloadZip "https://download.checkmarx.com/9.0.0/Plugins/CxConsolePlugin-9.00.2.zip" "plugins\CxConsolePlugin-9.00.2.zip"
DownloadZip "https://download.checkmarx.com/9.0.0/Plugins/Sonar-9.00.1.zip" "plugins\Sonar-9.00.1.zip"
DownloadZip "https://download.checkmarx.com/9.0.0/Plugins/Maven-9.00.1.zip" "plugins\Maven-9.00.1.zip"
DownloadZip "https://download.checkmarx.com/9.0.0/Plugins/CxViewerVSIX-9.00.2.zip" "plugins\CxViewerVSIX-9.0.2.zip"
DownloadZip "https://download.checkmarx.com/9.0.0/Plugins/CxEclipsePlugin-90.0.1.zip" "plugins\CxEclipsePlugin-90.0.1.zip"

Write-Host "Extracting Checkmarx Installer..."
extract

$pwd = Get-Location

Set-Location -Path installer *>> $global:logfile

Write-Host "Installing Checkmarx prerequisites..."
InstallCppRedist
InstallDotNet
InstallIIS

Write-Host "Installing Checkmarx..."
InstallCheckmarx

Set-Location -Path $pwd *>> $global:logfile

Write-Host "Setting Environment Variables..."
setEnvVars

Write-Host "Refreshing Environment Variables..."
refreshenv

Write-Host "Verifying OSA Health..."
osaHealth

Write-Host "Updating settings.xml file..."
updateSettingsXml

if ([System.IO.File]::Exists("C:\Program Files\Checkmarx\HID\HardwareId.txt")) {
  $hid = Get-Content -Path "C:\Program Files\Checkmarx\HID\HardwareId.txt"

  log "HID: $hid"
  Write-Host "HID: $hid"

  if ($hid) { 
    Write-Host "Done installing"

    Write-Host "`nEmail $global:logfile to Checkmarx to receive a license`n"
  } else {
    Write-Host "Installation did not complete.  Email $global:logfile to Checkmarx for further debug information`n"
  }
}

log "------------------ End of Installation ------------------"
