<#
	.SYNOPSIS
		Script to determine if systems have had Cryptolocker or Cryptowall ran on them, generates a report in Excel and CSV.
	.DESCRIPTION
		 Script to poll AD for all computers in a given target OU, then poll each said system to determine if remnants of Cryptolocker exist
	.Notes
		Author: CJ Hafner and Matt Varnell
#>


cls

try
	{
		if (-Not (Get-Module activedirectory))
		{
			Import-Module activedirectory -EA 'STOP' -Verbose:$false
		}
	}
	catch [Exception]
	{
	    Write-Warning "This script requires the ActiveDirectory components to be installed"
	    return;
}

$ObjectsOnly=$FALSE  #set to TRUE to only output objects - no excel - CSV will output either way. For Objects Only you can | objects to another stream to handle processing
$excelfilename="C:\CryptoStatResult"
$csvfilename="C:\CryptoStatResult"

#CHANGE SEARCHBASE TO BE YOUR ACTIVE DIRECTORY OU TO SEARCH
$searchBase = "Placeholder OU"

#Skip checking machines that haven't updated with AD (30 days is default)

$ExpiredMachineDays=-30

$JobsBufferMax=300 #halt processing every $JobsBufferMax machines to flush buffer for large OUs to prevent excessive memory consumption

[int]$ThreadLimit = 10 #threads for multitasking

	
$dateparts = Get-Date
$excelfilename=$excelfilename + $dateparts.Year + "-" + ("{0:d2}" -f $dateparts.Month) + "-" + ("{0:d2}" -f $dateparts.Day) + "-" + ("{0:d2}" -f $dateparts.Hour)
$csvfilename=$csvfilename + $dateparts.Year + "-" + ("{0:d2}" -f $dateparts.Month) + "-" + ("{0:d2}" -f $dateparts.Day) + "-" + ("{0:d2}" -f $dateparts.Hour) + ".csv"
Write-Host "File will save as $excelfilename $csvfilename"

$Script:SuspectAgents=0

$ProbeComputerScriptBlock = {
   Param (
      $computerADObj,
	  $OperatingSystem,
	  $PasswordLastSet,
	  $ExcelRow
   )
   
      
   #FUNCTIONS
	Function Get-WmiCustom([string]$computername,[string]$namespace,[string]$class,[int]$timeout=15)
	{
	#Function Get-WMICustom by MSFT's Daniele Muscetta - http://blogs.msdn.com/b/dmuscett/archive/2009/05/27/get_2d00_wmicustom.aspx
		$ConnectionOptions = new-object System.Management.ConnectionOptions
		$EnumerationOptions = new-object System.Management.EnumerationOptions
		$timeoutseconds = new-timespan -seconds $timeout
		$EnumerationOptions.set_timeout($timeoutseconds)
		$assembledpath = "\\" + $computername + "\" + $namespace
		#write-host $assembledpath -foregroundcolor yellow

		$Scope = new-object System.Management.ManagementScope $assembledpath, $ConnectionOptions
		
		try {
		$Scope.Connect()
		} catch {
		$result="Error Connecting " + $_
		return $Result 
		}

		$querystring = "SELECT * FROM " + $class
		#write-host $querystring

		$query = new-object System.Management.ObjectQuery $querystring
		$searcher = new-object System.Management.ManagementObjectSearcher
		$searcher.set_options($EnumerationOptions)
		$searcher.Query = $querystring
		$searcher.Scope = $Scope
		
		trap { $_ } $result = $searcher.get()

		return $result
	}

Clear-Variable onlinestatus,errorstatus,enabledstatus,windowsonline,WUServerKey,ServiceObj,ServiceObj,ServiceWMIObj,Aver,getthis,VersionAgentLink,PingFail,SuspectPermissions,StaleDNS,OS,IPAddress,ReverseLookup,FQDN -ErrorAction SilentlyContinue
$myhcol=1
$RegistryWMI=""
$CryptoStatusObject = New-Object psobject
$computername=[string]$computerADObj.name
$CryptoStatusObject | Add-Member NoteProperty -Name "ComputerName" -Value $ComputerName
$ErrorStatus=""
$CryptoStatusObject | Add-Member NoteProperty -Name "OS" -Value $OperatingSystem

Trap { 
	$ErrorStatus+= $_ + " "
	Continue
}

#Test if PC is online by pinging it, then accessing c$ 

$PingResponse=@(test-connection $computername -count 1)
if ($PingResponse.Count -gt 0) { 
	$path="\\" + $computername + "\c$"
	#Verify that account has permissions otherwise can fail
  	if (-not (Test-Path $path)) {
		$IPAddress=[string]$PingResponse[0].IPV4address.IpAddressToString
		$ReverseLookup=[System.Net.Dns]::GetHostEntry($IPAddress).HostName
		$FQDN=$ComputerName+ "." +  $env:userdnsdomain
		if ($ReverseLookup -notlike $FQDN) {
		$errorstatus +="Stale DNS; Forward lookup does not match reverse record. Stale record for $FQDN $ReverseLookup $IPAddress "
		$WindowsOnline=$False
		$ValidStatus=$False
		$StaleDNS=$True
		} else {
		$errorstatus += "$path is an invalid path, likely path due to security reasons "		
		#Windows actually IS online but we can't access C$
    	$WindowsOnline=$True
		$SuspectPermissions=$True  #Permissions check
		}
	} else {
	  	$WindowsOnline=$True
		
	} #end if test past fail
	$PingFail=$False
} else {
	$PingFail=$True
	$WindowsOnline=$False
	$ValidStatus=$False
} 

$CryptoStatus = $false

if ($WindowsOnline) {

                
	$SubKeyNames = $null
	$SubKeyNames = $null
   	$regSubKey2=$null
   	$Cryptowall=$false
   	$CryptoLocker=$false
   	$CryptoStatus=$false
  	$RemoteRegStarted=$False
	$Type = [Microsoft.Win32.RegistryHive]::Users
    $RegKeys=""    
		Try
           {
			$regKey = [Microsoft.Win32.RegistryKey]::OpenRemoteBaseKey($Type, $ComputerName)
            $subKeys = $regKey.GetSubKeyNames()
            }
            Catch{
			 	#$ServiceWMIObj=get-wmiobject win32_service -computername $computername -filter "name='RemoteRegistry'"
				$ServiceWMIObj=get-wmicustom -class "win32_service" -namespace "root\cimv2" -computername $computername –timeout 60 -erroraction stop
				$RegistryWMI=$ServiceWMIObj | where { $_.name -eq 'RemoteRegistry'}
					if ($RegistryWMI.State -ne 'Running') {
						$RegistryWMI.InvokeMethod("StartService",$null) | Out-Null
						$RemoteRegStarted=$True
						#write-debug  "* Remote Registry Started"
						Start-Sleep -m 1500
						#1.5 second delay
						try {
						$regKey = [Microsoft.Win32.RegistryKey]::OpenRemoteBaseKey($Type, $ComputerName)
                       	$subKeys = $regKey.GetSubKeyNames()
						} catch {
							Write-debug "Error reading registry after attempted start"
						}
						}
						 
						 
			}    #try/catch end catch for initial registry connection.
		
			if ($subkeys.Count -lt 1) {
		 	$ValidStatus=$False
		 	}
		
			$subKeys | %{
            	$key = "$_\software"
				Try
                   {
				   #"attempting scan for keys on $key $ComputerName"  | out-file  ($ComputerName + ".txt") -Append
                   $regSubKey = $regKey.OpenSubKey($key)
                   $SubKeyNames = $regSubKey.GetSubKeyNames()
                   if($SubKeyNames -match "CryptoLocker") {
                       	$CryptoStatus = $true
						$CryptoLocker=$True
					} 
					
					#	either way also check cryptlist
					#attempt to open the subkey of this subkey as CRYPTLIST
					$SubKeyNames | %{
		                $key2 = $key + "\" + "$_\CRYPTLIST"
						# --if wanting to test, create a fake registry key under software\random\NOTCLIST for example then key2:
						# $key2 = $Key + "\" + "$_\NotCList"
					    
						#"$computername Checking key2 : $key2 excel row $ExcelRow" | out-file $($ComputerName + ".txt") -append
						Try {
							$regSubKey2 = $regKey.OpenSubKey($key2)
			                #$SubKeyNames2 = $regSubKey2.GetSubKeyNames()
			                if($regSubKey2 -ne $null) {
								 #cryptowall exists
								 $CryptoStatus = $true
								 $Cryptowall=$True
							} 
						} catch {
						#nothing to search
						}
					} #end regsubkey foreach
					$ValidStatus=$true
                    }
                    
					Catch{
						#"Registry error $computername $_" | out-file $($ComputerName + ".txt") -append
						 #$errorstatus+="Registry access ERROR: $_ "
						 }                        
                 }
				 
				#now, as precaution retrace using wow6432node for possibility cryptowall/locker was 32 bit app using 32 bit registry hive. 
				$subKeys | %{
            	$key = "$_\software\Wow6432Node"
				Try
                   {
				   $regSubKey = $regKey.OpenSubKey($key)
                   $SubKeyNames = $regSubKey.GetSubKeyNames()
                   if($SubKeyNames -match "CryptoLocker") {
                       	$CryptoStatus = $true
						$CryptoLocker=$True
					} 
					
					#	either way also check cryptlist
					#attempt to open the subkey of this subkey as CRYPTLIST
					$SubKeyNames | %{
		                $key2 = $key + "\" + "$_\CRYPTLIST"
						# --if wanting to test, create a fake registry key under software\random\NOTCLIST for example then key2:
						# $key2 = $Key + "\" + "$_\NotCList"
					    
						Try {
							$regSubKey2 = $regKey.OpenSubKey($key2)
			                #$SubKeyNames2 = $regSubKey2.GetSubKeyNames()
			                if($regSubKey2 -ne $null) {
								 #cryptowall exists
								 $CryptoStatus = $true
								 $Cryptowall=$True
							} 
						} catch {
						#nothing to search
						}
					} #end regsubkey foreach
					$ValidStatus=$true
                    }
                    
					Catch{
						 #$errorstatus+="Registry access ERROR: $_ "
						 }                        
                 }
				 
				 
				 if ($RemoteRegStarted) {
				 # Stop it now...
				 	try {
					$RegistryWMI.InvokeMethod("StopService",$null) | Out-Null
					}
					catch {
					}
				}
} else {
		$ServiceWMIObj=""
} #endif windows online

$CryptoStatusObject | Add-Member NoteProperty -Name "WindowsOnline" -Value $WindowsOnline
if ($ValidStatus) {
	$CryptoStatusObject | Add-Member NoteProperty -Name "CryptoStatus" -Value $CryptoStatus
	$CryptoStatusObject | Add-Member NoteProperty -Name "Cryptowall" -Value $Cryptowall
	$CryptoStatusObject | Add-Member NoteProperty -Name "Cryptolocker" -Value $CryptoLocker
	if ($CryptoLocker) { 
		$errorstatus+="FOUND CRYPTOLOCKER "
		"$computername FOUND CRYPTOLOCKER $CRYPTOLOCKER"  | out-file C:\CRYPTOSCANRESULTS.TXT -append
		#--as a precaution in case anything else goes wrong write results to simple txt as well
	}
	if ($Cryptowall) {
		$errorstatus+="FOUND CRYPTOWALL "
		"$computername FOUND CRYPTOWALL $CRYPTOWALL" | out-file c:\CRYPTOSCANRESULTS.TXT -append
		#--as a precaution in case anything else goes wrong write results to simple txt as well
	}
	
} else {
		$CryptoStatusObject | Add-Member NoteProperty -Name "CryptoStatus" -Value "Unknown"
		$CryptoStatusObject | Add-Member NoteProperty -Name "Cryptowall" -Value "Unknown"
		$CryptoStatusObject | Add-Member NoteProperty -Name "Cryptolocker" -Value "Unknown"
}
$CryptoStatusObject | Add-Member NoteProperty -Name "ADPasswordDate" -Value $Passwordlastset
$CryptoStatusObject | Add-Member NoteProperty -Name "ErrorStatus" -Value $errorstatus

return $CryptoStatusObject

} # END SCRIPT BLOCK


Function ExcelTranslations($Object) {
$script:hcol=1
$script:servicesheet.Cells.Item($Script:hrow,$Script:hcol) = $Object.ComputerName
$Script:hcol=1+$Script:hcol
$script:servicesheet.Cells.Item($Script:hrow,$Script:hcol) = $Object.WindowsOnline
$Script:hcol=1+$Script:hcol

if ($Object.CryptoLocker -eq $true) { 
		$script:servicesheet.Cells.Item($Script:hrow,$Script:hcol) = "Cryptolocker FOUND"
} elseif ($Object.Cryptowall -eq $true) {
		$script:servicesheet.Cells.Item($Script:hrow,$Script:hcol) = "Cryptowall FOUND" 
} else {
	$script:servicesheet.Cells.Item($Script:hrow,$Script:hcol) = $Object.Cryptostatus
}
$Script:hcol=1+$Script:hcol


$script:servicesheet.Cells.Item($Script:hrow,$Script:hcol) = $Object.ADPasswordDate
$Script:hcol=1+$Script:hcol
$script:servicesheet.Cells.Item($Script:hrow,$Script:hcol) = $Object.OS
$Script:hcol=1+$Script:hcol

$Script:hrow=1+$Script:hrow
}


#MAIN FUNCTIONALITY BEGINS HERE.

Clear-Variable SuspectAgents -ErrorAction SilentlyContinue

$startdate = Get-Date -format G #record when we started this.



#Establish variable scope at root of script
$workbook=""
$excel=""
$script:servicesheet="" 

if (-not $ObjectsOnly) {
Write-Host  "Creating Excel Workbook 1"

$excel = New-Object -comobject Excel.Application
# disable excel alerting (For overwrite of file
$excel.DisplayAlerts = $False
$excel.Visible = $true
$workbook = $excel.Workbooks.Add()

 #Column Headings for DS Sheet
 
$script:servicesheet = $workbook.sheets.Item(1)

$headings = @("Name","Windows Online?","Cryptostatus?","AD Password Date","OS")
$Script:hrow = 1
$Script:hcol = 1
   	 
$script:servicesheet.Name = "Crytpolocker Status"
$headings | % { 
   	 $script:servicesheet.cells.item($Script:hrow,$Script:hcol)=$_
   	 $Script:hcol=1+$Script:hcol
}

### Formatting 
#$script:servicesheet.columns.item("D").Numberformat = "0"
$script:servicesheet.Rows.Font.Size = 10
$script:servicesheet.Rows.Item(1).Font.Bold = $true
$script:servicesheet.Rows.Item(1).Interior.Color = 0xBABABA
$script:servicesheet.activate()
$script:servicesheet.Application.ActiveWindow.SplitColumn = 0
$script:servicesheet.Application.ActiveWindow.SplitRow = 1
$script:servicesheet.Application.ActiveWindow.FreezePanes = $true
	
#define Numbers - start all at second row
$Script:hcol = [Int64]1
$Script:hrow = [Int64]2
	
} #end if not objectsonly

$ExpiredDate=(Get-date).AddDays($ExpiredMachineDays)


  
foreach ($currentOU in $searchBase) {
	#$workbook.SaveAs("c:\tempCrystatAll")
	Write-Host "`nProbing OU: $currentOU "
	$ADCompObject=get-adcomputer -filter {(enabled -eq "true") -and (passwordlastset -gt $ExpiredDate) -and ((OperatingSystem -notlike '*mac*')) } -SearchBase $currentOU -properties Name,PasswordLastSet,OperatingSystem
	$RunspacePool = [RunspaceFactory]::CreateRunspacePool(1, $ThreadLimit)
	$RunspacePool.Open()
	$Jobs = @()
	$JobNumber=0
	$OUCount=0
	
	foreach ($computerObject in $ADCompObject) {
		
		$JobNumber=1+$JobNumber
		$OUCount=1+$OUCount	
		$Job = [powershell]::Create().AddScript($ProbeComputerScriptBlock).AddArgument($computerObject).AddArgument($computerObject.OperatingSystem).AddArgument($computerObject.passwordlastset).AddArgument($script:hrow)
    	$Job.RunspacePool = $RunspacePool
   		$Jobs += New-Object PSObject -Property @{
   			RunNum = $JobNumber
			Pipe = $Job
			Result = $Job.BeginInvoke()
	  	}
			
		if (($JobNumber%$JobsBufferMax -eq 0) -or ($OUCount -eq $ADCompObject.Count)) {
		Write-Host "... Flushing Jobs buffer, count: $($Jobs.Count) completing - $OUCount of $($ADCompObject.Count) .." -NoNewline
		Do {
	  		 Write-Host "." -NoNewline
	  		 Start-Sleep -Seconds 1
		} While ( $Jobs.Result.IsCompleted -contains $false)
			
		ForEach ($Job in $Jobs) {
			$ProbeObject = @($Job.Pipe.EndInvoke($Job.Result))
			#Write-Host "Object is $($Probeobject[0])"
			if (-not $ObjectsOnly) {
				ExcelTranslations($ProbeObject[0])
			} else {
			#return object itself
				$ProbeObject[0]
			}
			
			#consider moving this to option alongside objects only
			$ProbeObject[0] | Export-Csv $CSVFileName -append -NoTypeInformation
			
			if (($ProbeObject[0].Cryptolocker -and ($ProbeObject[0].Cryptolocker -ne "Unknown")) -or ($ProbeObject[0].Cryptowall -and ($ProbeObject[0].Cryptowall -ne "Unknown"))) {
				#DO SOMETHING! ! ! 
				$Script:SuspectAgents+=1
				Write-Host "Cryptolocker found: $($ProbeObject[0].Cryptolocker) - Cryptowall found: $($ProbeObject[0].Cryptowall) on $($ProbeObject[0].computername)"
			} #end if somethign was found.
		} #end foreach jobs
		$Jobs = @()
		$JobNumber=0
		} #end if checking if buffer is full or we're at last computer in OU
		
	} #End Foreach Loop for $ComputerList
	
	#let current OU finish wrapping up before moving on

		
} #End ForEach Loop for $Ou $Searchbase

if (-not $ObjectsOnly) {
	 ### AutoFit Rows and Columns	
	$script:servicesheet.Rows.AutoFit() | Out-Null
	$script:servicesheet.Columns.AutoFit() | Out-Null
	$enddate = Get-Date -format G
	$script:hrow = 5+$script:hrow
	$script:servicesheet.cells.Item($script:hrow,"A") = "Suspect Clients: $Script:SuspectAgents" 
	$script:hrow = 1+$script:hrow
	$script:servicesheet.cells.Item($script:hrow,"A") = "Report Generated: $startdate - $enddate - Running as $env:username " 

	#SAVE Excel File
	#Note: Excel appends .xlsx file type
	$workbook.SaveAs($excelfilename)
	Write-Verbose "Done."
	## Close excel process 
	$workbook.Close()

	$excel.Quit()
	while( [System.Runtime.Interopservices.Marshal]::ReleaseComObject($script:servicesheet)){ }
	while( [System.Runtime.Interopservices.Marshal]::ReleaseComObject($workbook)){ }
	while( [System.Runtime.Interopservices.Marshal]::ReleaseComObject($excel)){ }
	
}