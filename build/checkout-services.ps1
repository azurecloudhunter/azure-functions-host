param (
  [string]$connectionString = ""
)

function AcquireLease($blob) {
  try {
    return $blob.ICloudBlob.AcquireLease($null, $null, $null, $null, $null)    
  } catch {
    Write-Host "  Error: $_"
    return $null
  } 
}

# get a blob lease to prevent test overlap
$storageContext = New-AzureStorageContext -ConnectionString $connectionString

# to maintain ordering across builds, only try to retrieve a lock when it's our turn
$queue = Get-AzureStorageQueue –Name 'build-order' –Context $storageContext
$queueMessage = New-Object -TypeName "Microsoft.WindowsAzure.Storage.Queue.CloudQueueMessage,$($queue.CloudQueue.GetType().Assembly.FullName)" -ArgumentList ""
Write-Host "$($queue.CloudQueue.GetType().Assembly.FullName)"
$queue.CloudQueue.AddMessage($queueMessage)
while ($queueMessage.Id -ne $null) { }
$messageId = $queueMessage.Id
Write-Host "Adding a queue message. This step will continue when this message is next on the queue."
Write-Host "Queue message id: '$messageId'"
Write-Host ""

$queuePollDelay = 10

while($true) {
  # wait until we're next in the queue
  $nextMessage = $queue.CloudQueue.PeekMessage()
  $nextMessageId = $nextMessage.Id
  Write-Host "Next message: '$nextMessageId'"
  
  if ($nextMessageId -eq $messageId) {
    Write-Host "This job is next in the queue. Proceeding to poll for blob lease."
    break
  }

  Write-Host "Waiting until this job is next in the queue. Will re-poll every $queuePollDelay seconds."
  
  Start-Sleep -s $queuePollDelay
  Write-Host ""
}

While($true) {
  $blobs = Get-AzureStorageBlob -Context $storageContext -Container "ci-locks"
  $token = $null
  
  # shuffle the blobs for random ordering
  $blobs = $blobs | Sort-Object {Get-Random}

  Write-Host "Looking for unleased ci-lock blobs (list is shuffled):"
  Foreach ($blob in $blobs) {
    $name = $blob.Name
    $leaseStatus = $blob.ICloudBlob.Properties.LeaseStatus
    
    Write-Host "  ${name}: $leaseStatus"
    
    if ($leaseStatus -eq "Locked") {
      continue
    }

    Write-Host "  Attempting to acquire lease on $name."
    $token = AcquireLease $blob
    if ($token -ne $null) {
      Write-Host "  Lease acquired on $name. LeaseId: '$token'"
      Write-Host "##vso[task.setvariable variable=LeaseBlob]$name"
      Write-Host "##vso[task.setvariable variable=LeaseToken]$token"
      break
    } else {
      Write-Host "  Lease not acquired on $name."
    }    
  }
  
  if ($token -ne $null) {
    break
  }
  
  $delay = 30
  Write-Host "No lease acquired. Waiting $delay seconds to try again. This run cannot begin until it acquires a lease on a CI test environment."
  Start-Sleep -s $delay
  Write-Host ""
}

# now delete the message so that others may continue
Write-Host ""
Write-Host "Retrieving and deleting message '$messageId' from queue."
$queueMessage = $queue.CloudQueue.GetMessage()
$queue.CloudQueue.DeleteMessage($queueMessage)