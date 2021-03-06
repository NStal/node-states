# States
#
# How it works
# 1. states should start from "void", there should be no atVoid handler.
# 2. by calling @error current state and error will be saved
#    and we will turn the state into "panic".
# 3. at "panic" states, state machine won't turn unless you call @recover()
#    or setState to "void" manually.
#    Latter one won't reset @panicError and @panicState.
# 4. you should do the error recovering in atPanic handler, or just emit "panic"
#    event to the parent.
# 5. all the local data should be store on @data, so we can easily recover
#    from the previous shutdown.
# 6. should be rebust against invalid states jump
# 7. we have a default atPanit state handler to just emit a "panic" event
#    so the parent of this state machine should come to rescue
#    but in case we know how to recover from the current state, we may over
#    write atPanic handler to suppress the panic event
# Note: Set state with same stateName of the current state again will do nothing.
#
#
# States using a unique Sole to prevent multiple running context
# at async action.
#
# atFetching:(sole)->
#    asyncFetchin ()=>
#        # check soles to prevent multiple runing context
#        if not @checkSole sole
#            return
#

if typeof Leaf isnt "undefined"
    EventEmitter = Leaf.EventEmitter
    Errors = Leaf.ErrorDoc.create()
        .define("AlreadyDestroyed")
        .define("InvalidState")
        .generate()
else
    EventEmitter = (require "eventex").EventEmitter
    Errors = (require "error-doc").create()
        .define("AlreadyDestroyed")
        .define("InvalidState")
        .generate()
class States extends EventEmitter
    @Errors = Errors
    constructor:()->
        @state = "void"
        @_sole = 1
        @lastException = null
        @states = {}
        @rescues = []
        @data = {}
        @forceAsync ?= false
#        @_listenBys = []
        if @_isDebugging
            @debug()
        super()
    declare:(states...)->
        for state in states
            @states[state] = state
    destroy:()->
        if @isDestroyed
            return;
        @emit "destroy"
        @isDestroyed = true
        @emit = ()->
        @on = ()->
        @once = ()->
        @removeAllListeners()

    extract:(fields...)->
        data = {}
        for item in fields
            data[item] = @data[item]
        return data
    setData:(data)->
        for prop of data
            if data.hasOwnProperty prop
                @data[prop] = data[prop]
    at:(state,callback)->
        handlerName = "at"+state[0].toUpperCase()+state.substring(1)
        this[handlerName] = callback
        return this
    _nextTick:(exec)->
        if typeof setImmediate isnt "undefined"
            fn = setImmediate
        else
            fn = (exec)=>
                timer = setTimeout ()=>
                    exec()
                ,4
                return timer
        return fn(exec)
    _clearTick:(timer)->
        if typeof setImmediate isnt "undefined"
            fn = clearImmediate
        else
            fn = clearTimeout
    setState:(state)->
        @_clearTick @_stateTimer
        if @forceAsync
            @_stateTimer = @_nextTick ()=>
                if @_isDebugging
                    @_setState state
                else
                    @_try ()=>
                        @_setState state
        else
            if @_isDebugging
                @_setState state
            else
                @_try ()=>
                    @_setState state
    _try:(fn)=>
        try
            fn()
        catch e
            @error e
    _setState:(state)->
        @_clearTick @_stateTimer
        if not state
            throw new Errors.InvalidState "Can't set invalid states #{state}"
        if @state is "panic" and state isnt "void"
            return
        if @isDestroyed
            return
        if @data.feeds
            for prop,item of @data.feeds
                item.feedListener = null
        @_sole += 1
        @stopWaiting()
        @previousState = @state
        @state = state
#        if @_waitingGiveName
#            throw new Errors.InvalidState "Can't change to state #{state} while waiting for #{@_waitingGiveName}"
        if @_isDebugging and @_debugStateHandler
            @_debugStateHandler()
        @emit "state",state
        @emit "state/#{state}"
        stateHandler = "at"+state[0].toUpperCase()+state.substring(1)
        if this[stateHandler]
            sole = @_sole
            this[stateHandler] ()=>
                sole isnt @_sole
        else if state not in ["void"]
            if console.warn
                console.warn "state handler #{stateHandler} not provided"
            else
                console.error "state handler #{stateHandler} not provided"
    error:(error)->
        @panicError = error
        @panicState = @state
        for rescue in @rescues
            if rescue.state is @panicState and (@panicError instanceof rescue.error or not rescue.error)
                if @_debugRescueHandler
                    @_debugRescueHandler()
                @recover()
                rescue.callback(error)
                break
        # does rescue handles all error
        if @panicError
            @setState "panic"
    recover:(recoverState)->
        # For safety, recover just do a respawn.
        # So every async call should be ignored,
        # only if they forgot to check sole.
        error = @panicError
        state = @panicState
        @respawn()
        if recoverState
            @setState recoverState
        return {error,state}
    rescue:(state,error,callback = ()->)->
        if not callback
            throw new Error "rescue should provide callbacks"
        @rescues.push {state,error,callback}
    give:(name,items...)->
        if @_waitingGiveName is name
            handler = @_waitingGiveHandler
            @_waitingGiveName = null
            @_waitingGiveHandler = null
            if @_isDebugging and @_debugRecieveHandler
                @_debugRecieveHandler(name,items...)
            handler.apply this,items
        return
    stopWaiting:(name)->
        if name
            if @_waitingGiveName is name
                @_waitingGiveName = null
                @_waitingGiveHandler = null
            else
                throw new Error "not waiting for #{name}"
        else
            @_waitingGiveName = null
            @_waitingGiveHandler = null

    isWaitingFor:(name)->
        if not name and @_waitingGiveName
            return true
        if name is @_waitingGiveName
            return true
        return false
    feed:(name,item)->
        @data.feeds ?= {}
        @data.feeds[name] ?= []
        @data.feeds[name].push(item)
        if listener = @data.feeds[name].feedListener
            @data.feeds[name].feedListener = null
            listener()
    consumeAll:(name)->
        if @data.feeds?[name]?
            length = @data.feeds[name].length or 0
            @data.feeds[name] = []
            return length
        return 0
    consume:(name)->
        if @data.feeds?[name]?
            return @data.feeds[name].shift()
        else
            return null
    consumeWhenAvailable:(name,callback)->
        @data.feeds ?= {}
        @data.feeds[name] ?= []
        if @data.feeds[name].length > 0
            callback @consume(name)
        else
            @data.feeds[name].feedListener = ()=>
                callback @consume(name)
                #console.error "startve"
            @emit "starve",name
            @emit "starve/#{name}"
    waitFor:(name,handler)->
        if @_waitingGiveName
            throw new Error "already waiting for #{@_waitingGiveName} and can't wait for #{name} now"
        @_waitingGiveName = name
        @_waitingGiveHandler = handler
        if @_isDebugging and @_debugWaitHandler
            @_debugWaitHandler()
        @emit "wait",name
        @emit "wait/#{name}"
    atPanic:()->

        if @_isDebugging and @_debugPanicHandler
            @_debugPanicHandler()
        @emit "panic",@panicError,@panicState
    reset:(data = {})->
        @data = data
        @respawn()
    getSole:()->
        return @_sole
    checkSole:(sole)->
        return @_sole is sole
    stale:(sole)->
        if typeof sole is "function"
            return sole()
        return @_sole isnt sole
    respawn:()->
        @_sole = @_sole or 1
        @_sole += 1
        @_waitingGiveName = null
        @_waitingGiveHandler = null
        @panicError = null
        @panicState = null
        @setState "void"
        @_clearTick @_stateTimer
        @clear()
#    listenBy:(who,event,callback)->
#        owner = null
#        for item in @_listenBys
#            if item.who is who
#                owner = item
#                break
#        if not owner
#            owner = {who:who,cases:[]}
#            @_listenBys.push owner
#        owner.cases.push {event:event,callback:callback}
#        @on event,callback
#    stopListenBy:(who,event)->
#        owner = null
#        for item in @_listenBys
#            if item.who is who
#                owner = item
#                break
#        if not owner
#            return
#        for item,index in owner.cases
#            if item and (item.event is event or not event)
#                @removeListener item.event,item.callback
#            owner.cases[index] = null
#        owner.cases = owner.cases.filter (item)->item
#        if owner.cases.length is 0
#            @_listenBys = @_listenBys.filter (item)->item isnt owner
    debug:(option = {})->
        close = option.close
        @_debugName = option.name or @constructor and @constructor.name or "Anonymouse"
        _console = option.console or console
        log = ()->
            if _console.debug
                _console.debug.apply _console,arguments
            else
                _console.log.apply _console,arguments
        if close
            @_isDebugging = false
        else
            @_isDebugging = true
        @_debugStateHandler ?= ()=>
            log "#{@_debugName or ''} state: #{@state}"
        @_debugWaitHandler ?= ()=>
            log "#{@_debugName or ''} waiting: #{@_waitingGiveName}"
        @_debugRescueHandler ?= ()=>
            log "#{@_debugName or ''} rescue: #{@panicState} => #{@panicError}"
        @_debugPanicHandler ?= ()=>
            log "#{@_debugName or ''} panic: #{JSON.stringify @panicError}"
        @_debugRecieveHandler ?= (name,data...)=>
            log "#{@_debugName or ''} recieve： #{name} => #{data.join(" ")}"
    clear:(handler)->
        if handler
            if @_clearHandler
                throw new Error "already has clear handler"
            @_clearHandler = handler
        else
            _handler = @_clearHandler
            @_clearHandler = null
            if _handler
                _handler()
if typeof Leaf isnt "undefined"
    Leaf.States = States
else
    module.exports = States
