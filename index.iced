crypto = require 'crypto'
stream = require 'stream'
SHA3 = require 'js-sha3'
RockSolidSocket = require 'rocksolidsocket'
MsgpackRPC = require 'msgpackrpc'
amqp = require 'amqplib/callback_api'
msgpack = require 'msgpack'
domain = require 'domain'
util = require 'util'
request = require 'request'
EventEmitter = require('events').EventEmitter
pjson = require './package.json'


amqpDomain = domain.create()
amqpDomain.on 'error', (err) =>
  console.log('[QUEUE] Error with queue: ' + err)

class Stampery

  ethSiblings: {}
  authed: false

  constructor : (@clientSecret, @env) ->
    @clientId = crypto
      .createHash('md5')
      .update(@clientSecret)
      .digest('hex')
      .substring(0, 15)

    if @env is 'beta'
      host = 'api-beta.stampery.com:4000'
    else
      host = 'api.stampery.com:4000'

    sock = new RockSolidSocket host
    @rpc = new MsgpackRPC 'stampery.3', sock
    await @_auth defer @authed
    if @authed
      @_connectRabbit()

  _connectRabbit : () =>
    if @beta
      await amqp.connect 'amqp://consumer:9FBln3UxOgwgLZtYvResNXE7@young-squirrel.rmq.cloudamqp.com/beta', defer err, @rabbit
    else
      await amqp.connect 'amqp://consumer:9FBln3UxOgwgLZtYvResNXE7@young-squirrel.rmq.cloudamqp.com/ukgmnhoi', defer err, @rabbit
    return console.log "[QUEUE] Error connecting #{err}" if err
    if @rabbit
      console.log '[QUEUE] Connected to Rabbit!'
      @emit 'ready'
      amqpDomain.add @rabbit
      @_handleQueueConsumingForHash @clientId
      @rabbit.on 'error', (err) =>
        @emit 'error', err
        @_connectRabbit

  _sha3Hash: (string, cb) ->
    cb SHA3.keccak_512(string).toUpperCase()

  _hashFile : (fd, cb) ->
    hash = new SHA3.keccak_512.create()

    fd.on 'end', () ->
      cb hash.hex()

    fd.on 'data', (data) ->
      hash.update data

  _auth : (cb) =>
    await @rpc.invoke 'auth', [@clientId, @clientSecret, "nodejs-" + pjson.version ], defer err, res
    if err
      @auth = false
      @emit 'error', "Couldn't authenticate"
      process.exit()
    cb true

  _handleQueueConsumingForHash: (queue) =>
    await @rabbit.createChannel defer err, @channel
    unless err
      @channel.consume "#{queue}-clnt", (queueMsg) =>
        # Nucleus response spec
        # [v, [sib], root, [chain, txid]]
        unpackedMsg = msgpack.unpack queueMsg.content
        # The original hash is the routing_key
        hash = queueMsg.fields.routingKey

          # ACKing the queue message
        @channel.ack queueMsg
        niceProof =  @_processProof hash, unpackedMsg
        @emit 'proof', hash, niceProof
    else
      @emit 'error', "Error #{err}"

  _processProof: (hash, raw_proof) =>
    {
      'hash': hash
      'version': raw_proof[0]
      'siblings': @_convertSiblingArray raw_proof[1]
      'root': raw_proof[2].toString 'utf8'
      'anchor':
        'chain': raw_proof[3][0]
        'tx': raw_proof[3][1].toString 'utf8'
    }

  _convertSiblingArray : (siblings) =>
    if siblings is ''
      []
    else
      siblings.map (v, i) ->
        v.toString()

  _merkleMixer : (a, b, cb) =>
    commuted = if a > b then a + b else b + a
    @_sha3Hash commuted, cb

  prove : (hash, proof, cb) =>
    await @checkSiblings hash, proof.siblings, proof.root, defer siblingsAreOK
    cb siblingsAreOK

  checkDataIntegrity : (data, proof, cb) ->
    await @hash data, defer hash
    @prove hash, proof, defer valid
    cb valid

  checkSiblings : (hash, siblings, root, cb) =>
    if siblings.length > 0
      head = siblings.slice(-1)
      tail = siblings.slice(0, -1)
      await @_merkleMixer hash, head, defer hash
      await @checkSiblings hash, tail, root, cb
    else
      cb hash is root

  checkRootInChain : (root, chain, txid, cb) =>
    f = @_getBTCtx
    if chain is 2
      f = @_getETHtx
    await f txid, defer data
    cb data.indexOf(root.toLowerCase()) >= 0

  stamp : (hash) ->
    console.log "\nStamping \n#{hash}"
    hash = hash.toUpperCase()
    @rpc.invoke 'stamp', [hash], (err, res) =>
      if err
        console.log "[RPC] Error: #{err}"
        @emit 'error', err

  hash : (data, cb) ->
    if data instanceof stream
      @_hashFile data, cb
    else
      @_sha3Hash data, (hash) ->
        cb hash.toUpperCase()

util.inherits Stampery, EventEmitter

module.exports = Stampery
