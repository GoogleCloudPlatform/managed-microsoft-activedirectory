$attributeURL = 'http://metadata.google.internal/computeMetadata/v1/instance/attributes'
$guestAttributesURL = 'http://metadata.google.internal/computeMetadata/v1/instance/guest-attributes'
$guestAttributesKey = 'enable-guest-attributes'
$domainKey = 'managed-ad-domain'
$forceKey = 'managed-ad-force'
$ouNameKey = 'managed-ad-ou-name'
$failureStopKey = 'managed-ad-domain-join-failure-stop'
$domainJoinStatus = 'managed-ad/domain-join-status'
$domainJoinFailureMessage = 'managed-ad/domain-join-failure-message'
$domainJoinFile = "$home\blob.txt"
$retryCount = 10
$endpoint='managedidentities.googleapis.com'
$tokenUrl = 'http://metadata.google.internal/computeMetadata/v1/instance/service-accounts/default/token'
$fullTokenUrl = "http://metadata/computeMetadata/v1/instance/service-accounts/default/identity?audience=$endpoint&format=full"

function Write-DjoinBlob {
    <#
    .SYNOPSIS
        Function to fix unicode characters in the domain join blob
        so that it is accepted by djoin.exe tool (offline domain join)
    .PARAMETER Blob
        Domain join blob string which is modified in this method and written to a file
    #>
    [Cmdletbinding()]
    param (
        [Parameter(Mandatory = $true)]
        [System.String]$Blob
    )

      try {
          $bytes = New-Object -TypeName byte[] -ArgumentList 2
          $bytes[0] = 255
          $bytes[1] = 254
          $fileStream = ([System.IO.FileInfo]$domainJoinFile).Openwrite()

          # Append Hash as byte
          $bytes += [System.Text.Encoding]::unicode.GetBytes($Blob)
          # Append two extra 0 bytes characters
          $bytes += 0
          $bytes += 0

          # Write back to the file
          $fileStream.write($bytes, 0, $bytes.Length)

          # Close the file Stream
          $fileStream.Close()
      }
      catch {
          $Error[0]
      }
}

function Get-Metadata {
  <#
    .SYNOPSIS
        Get metadata or guest attributes from the metadata server based on URL, with retries.
    .PARAMETER url
        Url to which the metadata is written. It could be a guest attribute or key value to metadata server.
  #>
  param (
  [parameter(Mandatory=$true)]
  [String]$url
  )
  for ($i=1; $i -le $retryCount; $i++) {
    try {
      $value = (Invoke-RestMethod -Headers @{'Metadata-Flavor' = 'Google'} -Uri $url)
      return $value
    }
    catch {
      Write-Debug "Failed to get metadata value attempt = $i"
    }
  }
  return ""
}

function Write-GuestAttribute {
  param (
    [Parameter(Mandatory=$true)]
    [String]$key,
    [Parameter(Mandatory=$false)]
    [String]$message
  )
  <#
    .SYNOPSIS
      Writes status messsage to the guest attribute with retries.
    .PARAMETER key
      Guest attribute key to which the guest attribute needs to be written.
    .PARAMETER message
      Message for the key in guest attribute.
  #>
  for ($i=1; $i -le $retryCount; $i++) {
    try {
      $value = (Invoke-RestMethod  -Method PUT -Body $message -Headers @{'Metadata-Flavor' = 'Google'} -Uri "$guestAttributesURL/$key")
      return $value
    }
    catch {
      Write-Output "Failed to write guest attribute $key. Attempt $i."
    }
  }
}


function Write-DjoinStatus {
  <#
    .SYNOPSIS
        Write-Attributes writes the domain join status as guest attributes if the guest attributes
        is enabled. For more details, see https://cloud.google.com/compute/docs/metadata/manage-guest-attributes.
    .PARAMETER djoinStatus
        djoinStatus is the status of domain join i.e. success or failure.
    .PARAMETER djoinFailureMessage
        djoinFailureMessage is the error message seen when domain join fails.
  #>
  param (
    [Parameter(Mandatory=$false)]
    [String]$djoinStatus,
    [Parameter(Mandatory=$false)]
    [String]$djoinFailureMessage
  )
  try {
    $enabled = Get-Metadata "$attributeURL/$guestAttributesKey"
  }
  catch {
    Write-Output 'Error while getting the status of guest attribute.'
    return
  }
  if ($enabled -eq $false) {
    Write-Output 'Guest attributes are not enabled. Cannot write domain join status'
    return
  }
  try {
    $value = Write-GuestAttribute $domainJoinStatus $djoinStatus
    Write-Output 'Successfully wrote the domain join status to guest attributes'
  }
  catch {
    Write-Output 'An error occurred. Unable to write to guest attributes'
    Write-Output $_.Exception
  }
  if ([string]::IsNullOrEmpty($djoinFailureMessage)) {
    return
  }
  try {
    $value = Write-GuestAttribute $domainJoinFailureMessage $djoinFailureMessage
    Write-Output 'Successfully wrote the domain join failure message to guest attributes'
  }
  catch {
    Write-Output 'An error occurred. Unable to write failure messsage to guest attributes'
    Write-Output $_.Exception
  }
}

function Perform-DomainJoin {
  Write-DjoinStatus -djoinStatus '' -djoinFailureMessage ''
  $domainName = Get-Metadata "$attributeURL/$domainKey"
  $fullTokenResponse = Get-Metadata $fullTokenUrl
  # Set default ou name as empty string
  $ouName = ''
  try {
   $ouName = (Get-Metadata "$attributeURL/$ouNameKey")
  }
  catch {
    Write-Output 'OUName StatusCode:' $_.Exception.Response.StatusCode.value__
    Write-Output 'OUName StatusDescription:' $_.Exception.Response.StatusDescription
  }

  $hostName = hostname

  $body = @{
    domain = $domainName
    ouName = $ouName
    vmIdToken = $fullTokenResponse
  }
  $forceFlag = Get-Metadata "$attributeURL/$forceKey"
  if ($forceFlag -eq $true) {
      $body.force = $true
  }

  $bodyJson = $body|ConvertTo-Json
  $domainJoinUrl = "https://$endpoint/v1/$domainName" + ':domainJoinMachine'
  $accessTokenResponse = Get-Metadata $tokenUrl

  $accessToken = $accessTokenResponse.access_token

  $header = @{
   'Accept'= 'application/json'
   'Authorization'="Bearer $accessToken"
  }
  $response = Invoke-RestMethod -Uri $domainJoinUrl -Method POST -Body $bodyJson -Headers $header -ContentType 'application/json'
  $blob = $response.domainJoinBlob

  Write-DjoinBlob -Blob $blob -Verbose

  Write-Output 'Performing domain join'
  $processResponse = START-PROCESS Djoin -windowstyle hidden -ArgumentList "/requestodj /loadfile $domainJoinFile /windowspath $env:SystemRoot /localos" -PassThru -Wait
  if ($processResponse.ExitCode -ne 0) {
    throw "Domain join command failed : $processResponse"
  }

  Write-Output 'Domain join finished, restarting'
  Write-DjoinStatus -djoinStatus 'success' -djoinFailureMessage ''

  Restart-Computer
}

try {
  # check if the VM is already part of domain
  if ((Get-WmiObject win32_computersystem).partofdomain -eq $true) {
    Write-Output 'VM already domain joined'
    exit
  }
  Perform-DomainJoin
}
catch {
  Write-Output "Domain join failed. An error occurred while performing domain join: $_"
  Write-DjoinStatus -djoinStatus 'failure' -djoinFailureMessage $_.Exception.Message
  try {
    $stopVMFlag = Get-Metadata "$attributeURL/$failureStopKey"
    if ($stopVMFlag -eq $true) {
      Write-Output 'Shutting down the computer'
      shutdown /s
    }
  } catch {
    Write-Output 'Failing to communicate with metadata server'
  }
}
finally {
  $exists = Test-Path $domainJoinFile
  if ($exists -eq $true) {
    Remove-Item -Path $domainJoinFile -Force
  }
}
