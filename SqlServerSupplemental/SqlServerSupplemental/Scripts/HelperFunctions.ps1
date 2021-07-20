<#
    .SYNOPSIS
    Establishes a connection to a SQL Server instance

    .PARAMETER ServerName
    Name of the SQL Server to connect

    .PARAMETER InstanceName
    Name of the instance to connect (Default is MSSQLSERVER)

    .PARAMETER Database
    Name of the database to use on the SQL instance (Default is m)

#>
function Connect-SQL
{
    [CmdletBinding()]
    param
    (
        [Parameter(Mandatory = $true)]
        [System.String]
        $ServerName,

        [Parameter()]
        [System.String]
        $InstanceName = 'MSSQLSERVER',

        [Parameter()]
        [System.String]
        $Database = 'tempdb'
    )

    if ($InstanceName -ne 'MSSQLSERVER')
    {
        Write-Verbose 'Appending instance name to server name'
        $ServerName += "\$InstanceName"
    }

    Write-Verbose 'Building connection string'
    $builder = New-Object System.Data.SqlClient.SqlConnectionStringBuilder

    # customize the connection string properties
    $builder['Data Source'] = $ServerName
    $builder['Initial Catalog'] = $Database
    $builder['Application Name'] = 'SCOM SharePoint Database Monitoring'
    $builder['Connect Timeout'] = 120
    $builder['Trusted_Connection'] = $true

    $sqlConnectionObject = New-Object System.Data.SqlClient.SqlConnection $builder.ConnectionString

    try 
    {
        Write-Verbose "Opening connection to '$ServerName'"
        $sqlConnectionObject.Open()
    }
    catch
    {
        # TODO: Create a common error handler
        throw $_
    }

    # return the cached connection object
    Write-Output $sqlConnectionObject -NoEnumerate
}

<#
    .SYNOPSIS
    Executes an ad-hoc SQL statement within a given database.

    .PARAMETER Connection
    DbConnection object for the SQL instance against which the command will execute.

    .PARAMETER DatabaseName
    The database in which the the SQL query will be executed.

    .PARAMETER QueryString
    String containing the T-SQL to be executed

    .PARAMETER QueryParameters
    Hashtable containing the names and values of all parameters for the query.

    .PARAMETER CommandTimeout
    The maximum number of seconds to wait before terminating a query. Specifying 
    zero (0) will allow the command to run indefinitely. (Default = 300)

    .PARAMETER WithResults
    Determines whether a resultset from the procedure is returned.
#>
function Invoke-SqlQuery
{
    [CmdletBinding()]
    [OutputType('Hashtable', ParameterSetName = 'WithResults')]
    param (
        [Parameter(Mandatory = $true, ValueFromPipeline = $true)]
        [System.Data.Common.DbConnection]
        $Connection,

        [Parameter()]
        [System.String]
        $DatabaseName,

        [Parameter(Mandatory = $true)]
        [System.String]
        $QueryString,

        [Parameter()]
        [Alias("Parameters")]
        [Hashtable] 
        $QueryParameters,

        [Int] 
        $CommandTimeout = 300,

        [Parameter(ParameterSetName = 'WithResults')]
        [Switch]
        $WithResults
    )

    ## create a command for executing
    $command = $Connection.CreateCommand()

    ## mark this as an ad-hoc query
    $command.CommandType = "Text"

    ## set the timeout for the command
    $command.CommandTimeout = $CommandTimeout

    ## attach the query string
    $command.CommandText = $QueryString

    # Apply query parameters to the command
    $command | Set-Parameters -QueryParameters $QueryParameters

    try
    {
        $executeParams = @{
            Connection    = $Connection
            CommandObject = $command
            DatabaseName  = $DatabaseName
            WithResults   = $WithResults
        }
        ## execute the query
        return Invoke-DbCommand @executeParams
    }
    catch
    {
        ## rethrow exception
        throw $_.Exception.ToString()
    }
    finally
    {
        ## dispose of the .net objects created
        $command.Dispose()
    }
}

<#
    .SYNOPSIS
    Binds a hashtable to the parameters in a query

    .PARAMETER CommandObject
    DbCommand instance to which the parameters will be bound.

    .PARAMETER QueryParameters
    Hashtable containing the names and values of all parameters for the query.
#>
function Set-Parameters
{
    [CmdletBinding()]
    param
    (
        [Parameter(Mandatory = $true, ValueFromPipeline = $true)]
        [System.Data.Common.DbCommand]
        $CommandObject,

        [Parameter()]
        [Hashtable]
        $QueryParameters
    )

    if ($null -eq $QueryParameters)
    {
        return
    }
    
    ## apply the parameters to the procedure
    if ($QueryParameters.Keys.Count -gt 0)
    {
        ## loop through each parameter passed
        foreach ($key in $QueryParameters.Keys)
        {
            $parameterName = $key

            # Ensure parameter is prefixed with an @ symbol
            if ($parameterName -notmatch '^@')
            {
                $parameterName = "@$parameterName"
            }

            ## add the parameter and its value
            $command.Parameters.AddWithValue($parameterName, $QueryParameters[$key]) > $null
        }
    }
}

<#
    .SYNOPSIS
    Executes a command against a database connection

    .DESCRIPTION
    Executes the specified DbCommand against the DbConnection, optionally
    returning the results.

    .PARAMETER Connection
    Database connection to use for execution

    .PARAMETER CommandObject
    DbCommand instance containing the command to be executed

    .PARAMETER WithResults
    Switch determinng whether a resultset from the procedure is returned.

    .EXAMPLE
    ExecuteDbCommand -Connection $Connection -CommandObject $CommandObject
#>
function Invoke-DbCommand
{
    [CmdletBinding()]
    param
    (
        [Parameter(Mandatory = $true)]
        [System.Data.Common.DbConnection] 
        $Connection,

        [Parameter()]
        [System.String]
        $DatabaseName,

        [Parameter(Mandatory = $true)]
        [System.Data.Common.DbCommand] 
        $CommandObject,

        [Switch] 
        $WithResults
    )

    try
    {
        if ($false -eq [String]::IsNullOrEmpty($DatabaseName))
        {
            Write-Verbose "Changing database to '$DatabaseName'"

            if ($Connection.Database -ne $DatabaseName)
            {
                # execute the procedure from within the requested database
                $Connection.ChangeDatabase($DatabaseName)
            }
        }

        # determines whether a resultset is required
        if ( $WithResults )
        {
            # array to store the results
            $resultSet = @()

            # execute the query and return the results
            $reader = $CommandObject.ExecuteReader()
            
            # parse the output into a custom object
            try
            {
                while ($reader.Read())
                {
                    # create a new hashtable to represent this row
                    $rowHashTable = @{}

                    # loop through the columns
                    for ( $i = 0; $i -lt $reader.VisibleFieldCount; $i++ )
                    {
                        # get the field name
                        $key = $reader.GetName($i)

                        # If the column has no name (or alias)
                        if ([String]::IsNullOrEmpty($key))
                        {
                            # Create our own based on the index
                            $key = "Unnamed_Column_$i"
                        }
                            
                        # get the value
                        $value = $reader[$i]

                        # add the column to our row
                        $rowHashTable += @{ $key = $value }
                    }

                    # append the new object to the resultset
                    $resultSet += New-Object PSObject -Property $rowHashTable
                }

                # close the reader
                $reader.Close()

                # Return the results
                return $resultSet
            }
            catch
            {
                # re-throw the exception
                throw $_.Exception.ToString()
            }
            finally
            {
                $reader.Dispose()
            }
        }
        else
        {
            # just execute, returning nothing
            $null = $CommandObject.ExecuteNonQuery()

            return $true
        }
    }
    catch
    {
        # re-throw the exception
        throw $_.Exception.ToString();
    }
    finally
    {
        # dispose of the .net objects created
        $CommandObject.Dispose()
    }
}
