fs         = require 'fs'
Emitter    = require 'emitter'
dcopy      = require 'deep-copy'
{deferred} = require 'decor'
{EOL}      = require 'os'

###

realized
--------

* internal polling loop per metricset might not be too smart
* more sensible perhaps for a calling parent loop to manage polling
* especially since the parent is likely also polling 
* with the resulting race condition therefore doing the foxtrot
* or playing musical chairs with itself in the mirror
* the music stops
* everybody either gets a chair, or bangs their head


moral of the story
------------------

* outside should not poll
* TODO: inside should publish events


realize (cont)
--------------

* most of the functionality here should be in a superclass, it will be repeated
* not so far fetched wanting to tinker with iface aliases, vlans, and such over a web api
* esp. eg. setting up a private vlan from some appserver vm onto some other dbserver vm on the fly


local
-----

* this module's privates
* accessable for testing via `.test()`
* obviously therefore also accessable in general (if used, expect no consistancy between versions)

`local.supported`      - platform is linux
`local.pollingError`   - undefined unless the last poll errored
`local.reading`        - contains the latest reading from /proc/net/dev
`local.interval`       - the interval of reading taking
`local.timer`          - the running timer loop reference
`local.polling`        - the poll is currently active
`local.pollTimestamp   - the most recen poll timestamp
`local.historyLength`  - keeps a history of readings
`local.history`        - Cambrian was fun, from an evolutionary progress prespective
                       - Also, i don't see much reason why range triggering can't be performed at the monitor agent
                       - Certainly lightens the load at the core
                       - First element in the history [] is the oldest
                       - Each element contains [timespan, reading] where timespan is milliseconds since the preceding reading
`local.emitter`        - emits 'counters' event with latest counter values at each poll
                       - emits 'deltas' event including pollspan (milliseconds) at each poll
                       - IMPORTANT, poller skips if it catches it's tail
`local.poke`           - a purposeless additional comment referring, in jest at my excessive annotations, to a non existant property
`remote.fondle`        - not yet implemented on facebook, but just you wait...

###

local = 

    supported: process.platform is 'linux'
    pollingError: undefined
    reading:  {}
    interval: 1000
    timer:    undefined
    polling:  false
    historyLength: 500 # thumbsuck
    history:  []
    emitter:  new Emitter

    counters: (opts, callback) ->

        #
        # * TODO: if the first call to current() happens before the first poll
        #         then things don't go quite as planned... 
        # 
        #         pending fix, start() is promised, dont call this until start resolves
        #

        #
        # responds synchronously or asynchronously
        # ----------------------------------------
        # 
        # * opts arg is present to support the web export (see below)
        #


        error = null
        unless local.supported 
            platform = process.platform
            error = new Error "Platform unsupported, expected: linux, got: #{platform}"
                            #
                            # * vertex does not handle this properly yet
                            #
            console.log error

        return callback error, local.reading if typeof callback is 'function'
        throw error unless local.supported
        return local.reading


    poll: -> 

        #
        # teenager, twenty-something, and certainly middle-aged load averages may lead to a 
        # situation where the previous poll has not completed by the next scheduled poll
        # 
        # this stops the birthdays piling up
        #

        return if local.polling
        local.polling = true


        #
        # previous reading into history
        # -----------------------------
        #

        now = new Date
        if local.pollTimestamp? 

            timespan = now - local.pollTimestamp
            local.history.push [ timespan, dcopy(local.reading) ]

            local.history.shift() while local.history.length > local.historyLength

        local.pollTimestamp = now
        


        #
        # ASSUMPTION: consistancy between linuxes/versions of content of /proc/net/dev
        # VERIFIED:   cat /etc/lsb-release | grep DESCRIPTION
        # 
        # * DISTRIB_DESCRIPTION="Ubuntu 12.04.3 LTS"
        #

        try data = fs.readFileSync '/proc/net/dev', 'utf8'
        catch error

            local.pollingError = error
            local.polling = false
            return

        local.pollingError = undefined
        data.split( EOL )[2..].map (line) -> 

            return if line.match /^\s*$/

            [ignore, iface, readings] = line.match /\s*(.*)\:(.*)/

            local.reading[iface] ||= {}

            keys = [ 
                'ignore'   # first item in match is the input string
                'rxBytes'
                'rxPackets'
                'rxErrs'
                'rxDrop'
                'xrFifo'
                'rxFrame'
                'rxCompressed'
                'rxMulticast'
                'txBytes'
                'txPackets'
                'txErrs'
                'txDrop'
                'txFifo'
                'txColls'
                'txCarrier'
                'txCompressed'
            ]

            readings.match( 

                /\s*(\d*)\s*(\d*)\s*(\d*)\s*(\d*)\s*(\d*)\s*(\d*)\s*(\d*)\s*(\d*)\s*(\d*)\s*(\d*)\s*(\d*)\s*(\d*)\s*(\d*)\s*(\d*)\s*(\d*)\s*(\d*)/ 

            ).map (value) -> 

                key = keys.shift()
                return if key is 'ignore'

                                            #
                                            # possibly hazardous
                                            #
                local.reading[iface][key] = parseInt value


            #
            # ASSUMPTION: [Array].map() does not break flow, therefore thigs are ready for emit
            #

            local.emitter.emit 'counters', local.reading, now
            local.emitter.emit 'deltas',   'pending'

            local.polling = false


    start: deferred (action) -> 

        if not local.supported then return action.reject( 
            new Error "Platform unsupported, expected: linux, got: #{process.platform}"
        )

        return action.resolve() if local.timer?  # already running

        local.poll()
        local.timer = setInterval local.poll, local.interval
        action.resolve()



    stop: -> 

        clearInterval local.timer
        local.timer = undefined


    ###

    vertex friendlyness
    -------------------

    * this config() function can be exported on a running vertex (see web exports below)
    * web hit: `config?interval=10000` will call the function with `opts.query.interval`
    * obviously having to pass opts.query.interval would seem a bit obtuse for local use, 
      so the function does a bit of juggling about that
    * admittedly this need could be considered a bit of a design wrinkle
        * missing:  Alternative
        * lastseen: 29th Feb, 2017

    ###

    config: (opts, callback) -> 

        params = opts || {}
        if opts.query? then params = opts.query

        #
        # TODO: 
        # * possibly use a decorator for that little switch-a-roo
        # * vertex exported function to support promise, weird mix of
        #   promises and callback in the module will confuse
        #

        results = 
            polling: local.timer?
            interval:
                value: local.interval
                changed: false
                previous: null
            history: 
                value: local.historyLength
                changed: false
                previous: null


        for key of params

            switch key

                when 'interval'

                    try 

                        continue if local.interval == params[key]

                        previous              = local.interval
                        local.interval        = parseInt params[key]

                        results[key].changed  = true
                        results[key].value    = local.interval
                        results[key].previous = previous

                        #
                        # * needs a restart on the new interval if running
                        # * if not running, it still wont be after this
                        #

                        if local.timer?

                            local.stop()
                            local.start()

                when 'history'

                    try 

                        continue if local.historyLength == params[key]

                        previous              = local.historyLength
                        local.historyLength   = parseInt params[key]

                        results[key].changed  = true
                        results[key].value    = local.historyLength
                        results[key].previous = previous




        if typeof callback is 'function' then callback null, results



###

web exports
-----------

* these functions become availiable over http if this component is grafted 
  onto a running [vertex](https://github.com/nomilous/vertex) routes tree
* still much to be done with vertex
* eg. roles in the export config below does nothing yet

###

local.counters.$www = {}
local.config.$www = roles: ['admin']


###

module / component exports
--------------------------

###


module.exports = 

    counters: local.counters
    start:    local.start
    stop:     local.stop
    config:   local.config
    on:   ->  local.emitter.on.apply   local.emitter, arguments
    once: ->  local.emitter.once.apply local.emitter, arguments
    off:  ->  local.emitter.off.apply  local.emitter, arguments



#
# * export for testing
# 

module.exports.test = -> local

