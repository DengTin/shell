import json
import sys
import datetime

jdata = sys.stdin.read()
if jdata is None or not jdata:
  print ''
  sys.exit(0)
  
data = json.loads(jdata)
#key = 'processGroups'
key = sys.argv[1]

# if get process group itself, then get it directly and print a json result
if key == 'rootGroup':
  groupDetails = {}
  groupDetails['timestamp'] = datetime.datetime.now().strftime("%Y-%m-%d %H:%M:%S:%f")
  groupDetails['id'] = data['component']['id']
  groupDetails['name'] = data['component']['name']
  groupDetails['runningCount'] = data['component']['runningCount']
  groupDetails['stoppedCount'] = data['component']['stoppedCount']
  groupDetails['invalidCount'] = data['component']['invalidCount']
  groupDetails['activeRemotePortCount'] = data['component']['activeRemotePortCount']
  groupDetails['inactiveRemotePortCount'] = data['component']['inactiveRemotePortCount']
  groupDetails['inputPortCount'] = data['component']['inputPortCount']
  groupDetails['outputPortCount'] = data['component']['outputPortCount']
  groupDetails['queuedCount'] = data['status']['aggregateSnapshot']['queuedCount']
  groupDetails['flowFilesReceived'] = data['status']['aggregateSnapshot']['flowFilesReceived']
  json_groupDetails = json.dumps(groupDetails)
  print json_groupDetails
  sys.exit(0)

# if it's remote process group ports, then get it directly
if key == 'rpgPorts':
  version = str(data['revision']['version'])
  revision = '{"version":' + version
  if "clientId" in data['revision']:
    clientId = str(data['revision']['clientId'])
    revision += ',"clientId":"' + clientId + '"'
  revision += '}'  
  ports = data['component']['contents']['inputPorts']
  for item in ports:
    if item['connected'] == True:
      print 'id:' + item['id'] + ';name:' + item['name'] + ';transmitting:' + str(item['transmitting']).lower() + ';revision:' + revision
  sys.exit(0)

if key not in data or len(data[key]) == 0:
  print ''
  sys.exit(0)

for item in data[key]:
  if key == 'processors':
    version = str(item['revision']['version'])
    revision = '{"version":' + version
    if "clientId" in item['revision']:
      clientId = str(item['revision']['clientId'])
      revision += ',"clientId":"' + clientId + '"'
    revision += '}'
    print 'id:' + item['component']['id'] + ';name:' + item['component']['name'] + ';revision:' + revision + ';state:' + item['component']['state']
  elif key == 'processGroups':
    print 'id:' + item['component']['id'] + ';name:' + item['component']['name'] + ';stoppedCount:' + str(item['component']['stoppedCount']) + ';invalidCount:' + str(item['component']['invalidCount']) + ';disabledCount:' + str(item['component']['disabledCount']) + ';inactiveRemotePortCount:' + str(item['component']['inactiveRemotePortCount']) + ';queuedCount:' + item['status']['aggregateSnapshot']['queuedCount']
  elif key == 'remoteProcessGroups':
    print 'id:' + item['component']['id'] + ';targetUris:' + item['component']['targetUris'] + ';transmitting:' + str(item['component']['transmitting']).lower() + ';activeRemoteInputPortCount:' + str(item['component']['activeRemoteInputPortCount'])
  elif key == 'connections':
    print 'sourceId:' + item['status']['sourceId'] + ';sourceName:' + item['status']['sourceName'] + ';destinationId:' + item['status']['destinationId'] + ';destinationName:' + item['status']['destinationName'] + ';queuedCount:' + item['status']['aggregateSnapshot']['queuedCount'] + ';destinationGroupId:' + item['destinationGroupId'] + ';destinationType:' + item['destinationType']