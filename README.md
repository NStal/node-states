# Design targets
1. Easy to write, no state matrix.
2. Friendly error handling.
3. Robust against unexpected async callback or state jump.
4. Easy debug.

# Basic ideas
1. Every statemachine start with state void.
2. All state related data should bind to `@data` of the state machine .
3. Statemachine can turn to panic or recover from it and restore to a correct state.
4. All async action between state should have a integrity check.
5. Statemachine can be reset by clean the `@data` and set the state to "void", without worry about unreturned callbacks.
6. Statemachine use a wait/give strategy to interact with other state machine to prevent unwanted state change.

# Install

```bash
npm install logicoma
```

# Example

Example can be found at ./example folder. Run it to see a debug output.

```coffee-script
# States = require("logicoma")
States = require("../")
# You can use error-doc to create beautiful error declares and checks.
Errors = require("error-doc").create()
    .define("CommunicationFailure")
    .define("BarginFailure")
    .define("ProgrammerError")
    .generate()
# You DON'T have to define a `Action` when using node-state.
# I just write them here for easier understanding.


class BuyCarProcedure extends States
    # How to buy a car
    # 1. goto shop
    # 2. bargin with shop manager (again and again)
    # 3. pay
    constructor:()->
        super()
        # `@give("startSignal")` should be called
        # to start the statemachine. If we are not
        # wait for `"startSignal"`, giving that one will
        # do nothing.
        @waitFor "startSignal",()=>
            # State will be changed
            # @atGotoShop will be called
            @setState "gotoShop"
    atGotoShop:(sole)->
        @waitFor "shopName",(name)=>
            @data.shopName = name
            @walkToShop name,(err)=>
                # Always do a integrity check for async action.
                # `sole` is given as state method parameters.
                if not @checkSole sole
                    return
                # go panic on error
                if err
                    @error err
                    return
                @setState "thinkOfAStartPrice"
    atThinkOfAStartPrice:()->
        @waitFor "startPrice",(price)=>
            @data.myPrice = price
            @setState "bargin"
    atBargin:(sole)->
        if not @data.myPrice
            @setState "thinkOfAStartPrice"
            return
        @bargin @data.myPrice,(err,result)=>
            if not @checkSole sole
                return
            if err
                @error err
                return
            if not result
                @data.myPrice += 100
                @setState "bargin"
            else
                @setState "pay"
    atPay:(sole)->
        @waitFor "money",(money)=>
            @pay money,(err)=>
                if not @checkSole sole
                    return
                if err
                    @error err
                    return
                @setState "paid"
    atPaid:()->
        @emit "paid"
    # Actions behaves just like a normal function.
    # They don't and shouldn't change state machine state, and
    # should better not change `@data`.
    walkToShop:(name,callback)->
        console.log "I walk to #{name} to buy a car"
        setTimeout callback,10
    bargin:(price,callback)->
        accept = 1000
        err = null
        console.log "I bid at price #{price}"
        if Math.random() > 0.85
            err = new Errors.CommunicationFailure("the manager say something I don't understand")
        else if Math.random() > 0.8
            err = new Errors.BarginFailure("the manager don't want to bargin with me any more")
        callback err,price > accept
    pay:(money,callback)->
        console.log "#{money} is given away."
        callback null


# All error handlings
p = new BuyCarProcedure()
# you can see all the state jump and actions
p.debug({name:"BuyCar"})


p.on "wait/shopName",()=>
    p.give("shopName","the car shop near my house")
p.on "wait/startPrice",()=>
    p.give("startPrice",500)
p.on "wait/money",()=>
    p.give("money",p.data.myPrice + "$")

# Suppose we are in a parent statemachine who
# is responsible for the error handling.
# If the error is simple enough and don't not require any third party
# information to handle it, we can also consider that sort of
# error a valid state.
# But here we handle them outside the statemachine to expalin a standard
# panic recover strategy here.

parentStateMachineData = {}
d = parentStateMachineData
p.on "panic",(err,state)=>
    if err instanceof Errors.CommunicationFailure and state is "bargin"
        # it's OK just bargin again!
        p.recover()
        p.setState "bargin"
    else if err instanceof Errors.BarginFailure and state is "bargin"
        d.failCount ?= 0
        d.failCount++
        if d.failCount < 3
            # we just try again
            p.recover()
            p.setState "bargin"
        else
            # a error that is impossible to handle
            console.log "I can't bargin with this asshole any more!"
            process.exit(0)
    else
        throw new Errors.ProgrammerError("I don't expect this kind of situation",{via:err,state:state})
p.on "paid",()->
    console.log "paid!"
# finally start the stae machine
p.give("startSignal")
```
