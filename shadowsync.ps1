#set strict mode
Set-StrictMode -Version 2.0

# ----------------------------------------------------------------------
#create a shadow copies and link to junction point
Function Create-ShadowCopy([string]$Drive, [string]$JunctionPoint) {
	$ShadowObject = (gwmi -List Win32_ShadowCopy).Create($drive, "ClientAccessible")
	$ShadowCopy = gwmi Win32_ShadowCopy | ? { $_.ID -eq $ShadowObject.ShadowID }

	#create symbolic link for directory
	$JunctionPath = ($script:SessionDir.FullName + "\" + $JunctionPoint)
	$ret = [Win32.Kernel32]::CreateSymbolicLink($JunctionPath, ($ShadowCopy.DeviceObject + "\"), 1 )

	#add to the list of shadow volumes
	$ShadowCopy.ExposedPath = $JunctionPath
	$script:ShadowVolumes += $ShadowCopy
}

# ----------------------------------------------------------------------
# Execute Backup
Function Make-Backup([array]$Sources) {
	Write-Host "Mirroring " $Sources

	$Success = $true

	$Args = @()

	# Recursive, preserve links, preserve modification times, compress
	$Args += "-rltz"

	# Make sure we do not recurse into our temporary session directory
	$Args += "--exclude=" + "'" + $Script:SessionGuid + "'"

	# Load any rsync options from the config file.
	[array]$options = $script:Conf.config.rsync.option
	if ($options.count -gt 0) {
		$Args += $options
	}

	# If we have a previous backup, use this as our hardlink tree source.
	if (Test-Path ($script:LastRunFile)) {
		$lastrun = "--link-dest=../" + (Get-Content ($script:LastRunFile))
		$Args += $lastrun

		# Remove (unlink) files which are no longer present.
		$Args += "--delete"
	}

	$Args += $Sources

	$User = $script:Conf.config.rsync.user
	$Server = $script:Conf.config.rsync.server
	$BasePath = $script:Conf.config.rsync.basepath

	$Remote = ""
	if ($Server.length -gt 0) {
		if (-Not(Test-Connection -ComputerName $Server -Quiet)) {
			Write-Host "Fatal: Backup server is down"
			return $false
		}
		if($User.length -gt 0) { $Remote = $user + "@" + $Server + ":" }
		else { $Remote = $Server + ":" }
	}

	$Args += $Remote + $BasePath + "/" + $ENV:ComputerName + "/" + $script:Now

	Write-Host 'rsync' $Args
	$SavedErrAction = $ErrorActionPreference
	$ErrorActionPreference = "Stop"
	try {
		$ret = & rsync $Args 2>&1  | Out-Host
	} catch {
		Write-Host "RSync: Caught Error"
		$Success = $false
	}
	$ErrorActionPreference = $SavedErrAction
	return $Success
}

# 
# ----------------------------------------------------------------------
#

#start logging
Start-Transcript -path ($ENV:Temp + "\backup_log.txt")

$ConfigDir = "C:\Backup"
$LastRunFile = $ConfigDir + "\lastrun.txt"

$SavedLocation = Get-Location
$ShadowVolumes = @()
$Now = Get-Date -UFormat "%Y-%m-%dT%H_%M_%S"

# load method from Kernel32.dll to create symlinks.
$MethodDefinition = @'
	[DllImport("kernel32.dll")]
	public static extern bool CreateSymbolicLink(string lpSymlinkFileName,
					string lpTargetFileName, int dwFlags);
'@
Add-Type -MemberDefinition $MethodDefinition -Name 'Kernel32' -Namespace 'Win32'

# Load configuration
if (-Not (Test-Path ($ConfigDir + "\config.xml"))) {
	Write-Host "Cannot find configuration file. Exiting."
	exit
}
[xml]$Conf = Get-Content ($ConfigDir + "\config.xml")

$SessionGuid = [system.guid]::newguid().tostring()

# Create a temporary working directory
$WorkDir = $ENV:Temp
# if($Conf.config.workdir) { $WorkDir = $Conf.config.workdir }
$SessionDir = new-item -type directory -path ($WorkDir + "\" + $SessionGuid)
Write-Host "Working Directory: " $SessionDir
cd $SessionDir

# Add Path to rsync to the environment path.
$RsyncDir = $Conf.config.rsync.dir
if($RsyncDir.length -gt 0) {
	$NewPath = ($RsyncDir + ";" + $Env:Path)
	$ENV:Path = $NewPath
}

try {
	foreach ($drv in $Conf.config.drives.drive) {
		Create-ShadowCopy $drv.name $drv.alias
	}

	$ret = Make-Backup $Conf.config.directories.dir.name
	if($ret) {
		Write-Host "Completed successfully. Updating timestamp file"
		Set-Content -Path $LastRunFile -Value $Now
	}

} finally {
	Write-Host "Cleaning up..."
	cd $SavedLocation
	$ShadowVolumes | ForEach-Object {
		[IO.Directory]::Delete(($_.ExposedPath))
		$_.Delete()
	}
	Remove-Item $SessionDir -recurse
}

#stop logging
Stop-Transcript
