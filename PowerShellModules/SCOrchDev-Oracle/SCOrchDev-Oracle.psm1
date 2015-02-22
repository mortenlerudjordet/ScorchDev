<# 
 .Synopsis
  Uses ODP .NET to query Oracle

 .Description
  Queries a ODP Database and returns result as PSobject list

 .Parameter query
  The ODP Query to run
 
 .Parameter ODPConnection
  A list of ODPParameters to pass to the query, pass in object with parameteres set
  @{
  'HostName'    = 
  'HostPort'    =
  'ServiceName' =
  'UserName'    =
  'Password'    =
  }

   .Parameter TimeOut
   timeout property for ODP query. Default is 60 seconds

 .Example

   
#>
Function Invoke-ODPQuery
{
    [CmdletBinding()]
    PARAM (
        [Parameter(ParameterSetName='ODPConnection',Mandatory=$true,HelpMessage='Please specify the DB Connection object')][Alias('Connection','c')]
        [ValidateNotNullOrEmpty()]
        [Object]$ODPConnection,
		[Parameter(ParameterSetName='IndividualParameter',Mandatory=$true,HelpMessage='Please enter the user name to connect to the ODP DB')][Alias('u')]
        [ValidateNotNullOrEmpty()]
        [String]$Username,
        [Parameter(ParameterSetName='IndividualParameter',Mandatory=$true,HelpMessage='Please enter the password to connect to the ODP DB')][Alias('p')]
        [ValidateNotNullOrEmpty()]
        [String]$Password,
		[Parameter(ParameterSetName='IndividualParameter',Mandatory=$true,HelpMessage='Please enter host name of ODP database')][Alias('Host','h')]
        [ValidateNotNullOrEmpty()]
        [string]$HostName,
		[Parameter(ParameterSetName='IndividualParameter',Mandatory=$true,HelpMessage='Please enter the instance in ODP database')][Alias('Service','s')]
        [ValidateNotNullOrEmpty()]
        [string]$ServiceName,
		[Parameter(ParameterSetName='IndividualParameter',Mandatory=$true,HelpMessage='Please enter the port of the ODP database')][Alias('Port','p')]
        [ValidateNotNullOrEmpty()]
        [string]$HostPort,
		[Parameter(Mandatory=$true,HelpMessage='ODP Query to run')][Alias('q')]
		[ValidateNotNullOrEmpty()]
		[string]$Query,
		[Parameter(Mandatory=$false,HelpMessage='Timeout value for DB query')][Alias('t')]
		[ValidateNotNullOrEmpty()]
		[int]$TimeOut = 60
	)
	
	If ($ImportOracleAssembly -eq $false)
	{
		Write-Error -Message "Unable to load Oracle Client DLLs. Aborting"
		Return
	}
	
	# Check if server is online
    If(!(Test-Connection -ComputerName $ODPConnection.HostName)) {
        Write-Error -Message "Could not connect to database server"
		
        Return
    }
	If($ODPConnection) {
		$connection = New-ODPConnection -ODPConnection $ODPConnection
	}
	Else {
		$connection = New-ODPConnection -HostName $HostName -HostPort $HostPort -ServiceName $ServiceName -UserName $Username -Password $Password
	}
	
	# convert parameter string to array of ODPParameters
    try
    {
		Write-Verbose -Message "`$query [$query]"
		Write-Verbose -Message "`$timeout [$timeout]"
		
        $ODPConnection = New-Object Oracle.ManagedDataAccess.Client.OracleConnection($connection)
        $ODPConnection.Open()

        #Create a command object
        $ODPCommand = $ODPConnection.CreateCommand()
        $ODPCommand.CommandText = $Query
		$ODPCommand.CommandTimeout = $timeout

        $DataAdapter = New-Object Oracle.ManagedDataAccess.Client.OracleDataAdapter($ODPCommand)
		
		$ResultSet = New-Object System.Data.DataTable
		[void]$DataAdapter.fill($ResultSet)
		
		If(!($ResultSet.HasErrors)) {
			# Check if data was returned in query
			Write-Debug -Message "Number of Rows: $($ResultSet.Rows.Count)"
			If($ResultSet.Rows.Count -gt 0) {
				$ResultObjects = @()
				ForEach($Row in $ResultSet.Rows) {
					$ResultObject = @{}
					# Get all properties exposed in from Query
					$Properties = Get-Member -InputObject $Row -MemberType Property | Select-Object -Property Name
					# Create objects with all properties and add the values of these
					ForEach($Property in $Properties) {
						Write-Debug -Message "Processing property: $($Property.Name)"
						# Add all properties and its values to User object
						$ResultObject.($Property.Name) = $row.($Property.Name)
					}
					
					Write-Debug -Message "Data: $($ResultObject)"
					$ResultObjects += $ResultObject
					$ResultObject = $Null
				}
			}
			Else {
				Write-Verbose -Message "No rows in ResultSet"
			}
		}
		Else {
			Write-Error -Message "Error retrieving data from DB: $($ResultSet.GetErrors())"
		}
        Return $ResultObjects
    }
	Catch {
		Write-Error -Message "$($_.Exception.ToString())"
	} 
    finally
    {
        if($ODPConnection.State -eq 'Open')
        {
            Write-Debug -Message "Closing DB connection"
			$ODPConnection.Close();
        }
    }
}
Function Import-OracleAssembly
{
<# 
 .Synopsis
  Load Oracle Client DLLs

 .Description
   Load Oracle Client DLLs from either the Global Assembly Cache or from the DLLs located in PS module directory. It will use GAC if the DLLs are already loaded in GAC.

#>
   
    $DLLPath = (Get-Module FormulaModule).ModuleBase
    $arrDLLs = @()
    $arrDLLs += 'Oracle.ManagedDataAccess.dll'
	$AssemblyVersion = "4.121.2.0"
	$AssemblyPublicKey = "89b483f429c47342"
    #Load Oracle Client SDKs
    $bOracleLoaded = $true

    Foreach ($DLL in $arrDLLs)
    {
        $AssemblyName = $DLL.TrimEnd('.dll')
        If (!([AppDomain]::CurrentDomain.GetAssemblies() |Where-Object { $_.FullName -eq "$AssemblyName, Version=$AssemblyVersion, Culture=neutral, PublicKeyToken=$AssemblyPublicKey"}))
		{
			Write-verbose 'Loading Assembly $AssemblyName...'
			Try {
                $DLLFilePath = Join-Path $DLLPath $DLL
                [Void][System.Reflection.Assembly]::LoadFrom($DLLFilePath)
            } Catch {
                Write-Verbose "Unable to load $DLLFilePath. Please verify if the DLLs exist in this location!"
                $bOracleLoaded = $false
            }
		}
    }
    $bOracleLoaded
}

Function New-ODPConnection
{
<# 
 .Synopsis

#>
    [CmdletBinding()]
    PARAM (
        [Parameter(ParameterSetName='ODPConnection',Mandatory=$true,HelpMessage='Please specify the DB Connection object')][Alias('Connection','c')]
        [ValidateNotNullOrEmpty()]
        [Object]$ODPConnection,
        [Parameter(ParameterSetName='IndividualParameter',Mandatory=$true,HelpMessage='Please enter the user name to connect to the Formula DB')][Alias('u')]
        [ValidateNotNullOrEmpty()]
        [String]$Username,
        [Parameter(ParameterSetName='IndividualParameter',Mandatory=$true,HelpMessage='Please enter the password to connect to the Formula DB')][Alias('p')]
        [ValidateNotNullOrEmpty()]
        [String]$Password,
		[Parameter(ParameterSetName='IndividualParameter',Mandatory=$true,HelpMessage='Please enter host name of Formula database')][Alias('Host')]
        [ValidateNotNullOrEmpty()]
        [string]$HostName,
		[Parameter(ParameterSetName='IndividualParameter',Mandatory=$true,HelpMessage='Please enter the instance in Formula database')][Alias('Service')]
        [ValidateNotNullOrEmpty()]
        [string]$ServiceName,
		[Parameter(ParameterSetName='IndividualParameter',Mandatory=$true,HelpMessage='Please enter the port of the Formula database')][Alias('Port')]
        [ValidateNotNullOrEmpty()]
        [string]$HostPort
    )

	# Create the oracle connection string based on input values
	If ($ODPConnection)
	{
		$connection = "User Id=$($ODPConnection.UserName);Password=$($ODPConnection.Password);" +
		"Data Source=(DESCRIPTION=(ADDRESS_LIST=(ADDRESS=(PROTOCOL=TCP)(HOST=$($ODPConnection.HostName))(PORT=$($ODPConnection.HostPort))))" +
		"(CONNECT_DATA=(SERVICE_NAME=$($ODPConnection.ServiceName))))"		

	} else {
		$connection = "User Id=$($UserName);Password=$($Password);Data Source=(DESCRIPTION=(ADDRESS_LIST=(ADDRESS=(PROTOCOL=TCP)(HOST=$($HostName))(PORT=$($HostPort))))(CONNECT_DATA=(SERVICE_NAME=$($ServiceName))))"
	}
	
	Return $connection
}
Export-ModuleMember -Function * -Verbose:$false