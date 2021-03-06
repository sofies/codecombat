CocoClass = require 'lib/CocoClass'
{me} = require 'lib/auth'
Layer = require './Layer'
IndieSprite = require 'lib/surface/IndieSprite'
WizardSprite = require 'lib/surface/WizardSprite'
FlagSprite = require 'lib/surface/FlagSprite'
CocoSprite = require 'lib/surface/CocoSprite'
Mark = require './Mark'
Grid = require 'lib/world/Grid'

module.exports = class SpriteBoss extends CocoClass
  subscriptions:
    'bus:player-joined': 'onPlayerJoined'
    'bus:player-left': 'onPlayerLeft'
    'level:set-debug': 'onSetDebug'
    'sprite:highlight-sprites': 'onHighlightSprites'
    'surface:stage-mouse-down': 'onStageMouseDown'
    'level:select-sprite': 'onSelectSprite'
    'level:suppress-selection-sounds': 'onSuppressSelectionSounds'
    'level:lock-select': 'onSetLockSelect'
    'level:restarted': 'onLevelRestarted'
    'god:new-world-created': 'onNewWorld'
    'god:streaming-world-updated': 'onNewWorld'
    'camera:dragged': 'onCameraDragged'
    'sprite:loaded': -> @update(true)
    'level:flag-color-selected': 'onFlagColorSelected'
    'level:flag-updated': 'onFlagUpdated'
    'surface:flag-appeared': 'onFlagAppeared'
    'surface:remove-selected-flag': 'onRemoveSelectedFlag'

  constructor: (@options) ->
    super()
    @dragged = 0
    @options ?= {}
    @camera = @options.camera
    @surfaceLayer = @options.surfaceLayer
    @surfaceTextLayer = @options.surfaceTextLayer
    @world = options.world
    @options.thangTypes ?= []
    @sprites = {}
    @spriteArray = []  # Mirror @sprites, but faster for when we just need to iterate
    @selfWizardSprite = null
    @createLayers()
    @spriteSheetCache = {}
    @pendingFlags = []

  destroy: ->
    @removeSprite sprite for thangID, sprite of @sprites
    @targetMark?.destroy()
    @selectionMark?.destroy()
    super()

  toString: -> "<SpriteBoss: #{@spriteArray.length} sprites>"

  thangTypeFor: (type) ->
    _.find @options.thangTypes, (m) -> m.get('original') is type or m.get('name') is type

  createLayers: ->
    @spriteLayers = {}
    for [name, priority] in [
      ['Land', -40]
      ['Ground', -30]
      ['Obstacle', -20]
      ['Path', -10]
      ['Default', 0]
      ['Floating', 10]
    ]
      @spriteLayers[name] = new Layer name: name, layerPriority: priority, transform: Layer.TRANSFORM_CHILD, camera: @camera
    @surfaceLayer.addChild _.values(@spriteLayers)...

  layerForChild: (child, sprite) ->
    unless child.layerPriority?
      if thang = sprite?.thang
        child.layerPriority = thang.layerPriority
        child.layerPriority ?= 0 if thang.isSelectable
        child.layerPriority ?= -40 if thang.isLand
    child.layerPriority ?= 0
    return @spriteLayers['Default'] unless child.layerPriority
    layer = _.findLast @spriteLayers, (layer, name) ->
      layer.layerPriority <= child.layerPriority
    layer ?= @spriteLayers['Land'] if child.layerPriority < -40
    layer ? @spriteLayers['Default']

  addSprite: (sprite, id=null, layer=null) ->
    id ?= sprite.thang.id
    console.error 'Sprite collision! Already have:', id if @sprites[id]
    @sprites[id] = sprite
    @spriteArray.push sprite
    sprite.imageObject.layerPriority ?= sprite.thang?.layerPriority
    layer ?= @spriteLayers['Obstacle'] if sprite.thang?.spriteName.search(/(dungeon|indoor).wall/i) isnt -1
    layer ?= @layerForChild sprite.imageObject, sprite
    layer.addChild sprite.imageObject
    layer.updateLayerOrder()
    sprite

  createMarks: ->
    @targetMark = new Mark name: 'target', camera: @camera, layer: @spriteLayers['Ground'], thangType: 'target'
    @selectionMark = new Mark name: 'selection', camera: @camera, layer: @spriteLayers['Ground'], thangType: 'selection'

  createSpriteOptions: (options) ->
    _.extend options, camera: @camera, resolutionFactor: 4, groundLayer: @spriteLayers['Ground'], textLayer: @surfaceTextLayer, floatingLayer: @spriteLayers['Floating'], spriteSheetCache: @spriteSheetCache, showInvisible: @options.showInvisible

  createIndieSprites: (indieSprites, withWizards) ->
    unless @indieSprites
      @indieSprites = []
      @indieSprites = (@createIndieSprite indieSprite for indieSprite in indieSprites) if indieSprites
    if withWizards and not @selfWizardSprite
      @selfWizardSprite = @createWizardSprite thangID: 'My Wizard', isSelf: true, sprites: @sprites

  createIndieSprite: (indieSprite) ->
    unless thangType = @thangTypeFor indieSprite.thangType
      console.warn "Need to convert #{indieSprite.id}'s ThangType #{indieSprite.thangType} to a ThangType reference. Until then, #{indieSprite.id} won't show up."
      return
    sprite = new IndieSprite thangType, @createSpriteOptions {thangID: indieSprite.id, pos: indieSprite.pos, sprites: @sprites, team: indieSprite.team, teamColors: @world.getTeamColors()}
    @addSprite sprite, sprite.thang.id

  createOpponentWizard: (opponent) ->
    # TODO: colorize name and cloud by team, colorize wizard by user's color config, level-specific wizard spawn points
    sprite = @createWizardSprite thangID: opponent.id, name: opponent.name, codeLanguage: opponent.codeLanguage
    if not opponent.levelSlug or opponent.levelSlug is 'brawlwood'
      sprite.targetPos = if opponent.team is 'ogres' then {x: 52, y: 52} else {x: 28, y: 28}
    else if opponent.levelSlug in ['dungeon-arena', 'sky-span']
      sprite.targetPos = if opponent.team is 'ogres' then {x: 72, y: 39} else {x: 9, y: 39}
    else if opponent.levelSlug is 'criss-cross'
      sprite.targetPos = if opponent.team is 'ogres' then {x: 50, y: 12} else {x: 0, y: 40}
    else
      sprite.targetPos = if opponent.team is 'ogres' then {x: 52, y: 28} else {x: 20, y: 28}

  createWizardSprite: (options) ->
    sprite = new WizardSprite @thangTypeFor('Wizard'), @createSpriteOptions(options)
    @addSprite sprite, sprite.thang.id, @spriteLayers['Floating']

  onPlayerJoined: (e) ->
    # Create another WizardSprite, unless this player is just me
    pid = e.player.id
    return if pid is me.id
    wiz = @createWizardSprite thangID: pid, sprites: @sprites
    wiz.animateIn()
    state = e.player.wizard or {}
    wiz.setInitialState(state.targetPos, @sprites[state.targetSprite])

  onPlayerLeft: (e) ->
    pid = e.player.id
    @sprites[pid]?.animateOut => @removeSprite @sprites[pid]

  onSetDebug: (e) ->
    return if e.debug is @debug
    @debug = e.debug
    sprite.setDebug @debug for sprite in @spriteArray

  onHighlightSprites: (e) ->
    highlightedIDs = e.thangIDs or []
    for thangID, sprite of @sprites
      sprite.setHighlight? thangID in highlightedIDs, e.delay

  addThangToSprites: (thang, layer=null) ->
    return console.warn 'Tried to add Thang to the surface it already has:', thang.id if @sprites[thang.id]
    thangType = _.find @options.thangTypes, (m) ->
      return false unless m.get('actions') or m.get('raster')
      return m.get('name') is thang.spriteName
    thangType ?= _.find @options.thangTypes, (m) -> return m.get('name') is thang.spriteName
    return console.error "Couldn't find ThangType for", thang unless thangType

    options = @createSpriteOptions thang: thang
    options.resolutionFactor = if thangType.get('kind') is 'Floor' then 2 else SPRITE_RESOLUTION_FACTOR
    sprite = new CocoSprite thangType, options
    @listenTo sprite, 'sprite:mouse-up', @onSpriteMouseUp
    @addSprite sprite, null, layer
    sprite.setDebug @debug
    sprite

  removeSprite: (sprite) ->
    sprite.imageObject.parent.removeChild sprite.imageObject
    thang = sprite.thang
    delete @sprites[sprite.thang.id]
    @spriteArray.splice @spriteArray.indexOf(sprite), 1
    @stopListening sprite
    sprite.destroy()
    sprite.thang = thang  # Keep around so that we know which thang the destroyed thang was for

  updateSounds: ->
    sprite.playSounds() for sprite in @spriteArray  # hmm; doesn't work for sprites which we didn't add yet in adjustSpriteExistence

  update: (frameChanged) ->
    @adjustSpriteExistence() if frameChanged
    sprite.update frameChanged for sprite in @spriteArray
    @updateSelection()
    @spriteLayers['Default'].updateLayerOrder()
    @cache()

  adjustSpriteExistence: ->
    # Add anything new, remove anything old, update everything current
    updateCache = false
    itemsJustEquipped = []
    for thang in @world.thangs when thang.exists and thang.pos
      itemsJustEquipped = itemsJustEquipped.concat @equipNewItems thang
      if sprite = @sprites[thang.id]
        sprite.setThang thang  # make sure Sprite has latest Thang
      else
        sprite = @addThangToSprites(thang)
        Backbone.Mediator.publish 'surface:new-thang-added', thang: thang, sprite: sprite
        updateCache = updateCache or sprite.imageObject.parent is @spriteLayers['Obstacle']
        sprite.playSounds()
    item.modifyStats() for item in itemsJustEquipped
    for thangID, sprite of @sprites
      missing = not (sprite.notOfThisWorld or @world.thangMap[thangID]?.exists)
      isObstacle = sprite.imageObject.parent is @spriteLayers['Obstacle']
      updateCache = updateCache or (isObstacle and (missing or sprite.hasMoved))
      sprite.hasMoved = false
      @removeSprite sprite if missing
    @cache true if updateCache and @cached

    # mainly for handling selecting thangs from session when the thang is not always in existence
    if @willSelectThang and @sprites[@willSelectThang[0]]
      @selectThang @willSelectThang...

  equipNewItems: (thang) ->
    itemsJustEquipped = []
    if thang.equip and not thang.equipped
      thang.equip()  # Pretty hacky, but needed since initialize may not be called if we're not running Systems.
      itemsJustEquipped.push thang
    if thang.inventoryIDs
      # Even hackier: these items were only created/equipped during simulation, so we reequip here.
      for slot, itemID of thang.inventoryIDs
        item = @world.getThangByID itemID
        unless item.equipped
          console.log thang.id, 'equipping', item, 'in', thang.slot, 'Surface-side, but it cannot equip?' unless item.equip
          item.equip()
          itemsJustEquipped.push item
    return itemsJustEquipped

  cache: (update=false) ->
    return if @cached and not update
    wallSprites = (sprite for sprite in @spriteArray when sprite.thangType?.get('name').search(/(dungeon|indoor).wall/i) isnt -1)
    return if _.any (s.stillLoading for s in wallSprites)
    walls = (sprite.thang for sprite in wallSprites)
    @world.calculateBounds()
    wallGrid = new Grid walls, @world.size()...
    for wallSprite in wallSprites
      wallSprite.updateActionDirection wallGrid
      wallSprite.updateScale()
      wallSprite.updatePosition()
    #console.log @wallGrid.toString()
    @spriteLayers['Obstacle'].uncache() if @spriteLayers['Obstacle'].cacheID  # might have changed sizes
    @spriteLayers['Obstacle'].cache()
    # test performance of doing land layer, too, to see if it's faster
#    @spriteLayers['Land'].uncache() if @spriteLayers['Land'].cacheID  # might have changed sizes
#    @spriteLayers['Land'].cache()
    # I don't notice much difference - Scott
    @cached = true

  spriteFor: (thangID) -> @sprites[thangID]

  onNewWorld: (e) ->
    @world = @options.world = e.world

  play: ->
    sprite.play() for sprite in @spriteArray
    @selectionMark?.play()
    @targetMark?.play()

  stop: ->
    sprite.stop() for sprite in @spriteArray
    @selectionMark?.stop()
    @targetMark?.stop()

  # Selection

  onSuppressSelectionSounds: (e) -> @suppressSelectionSounds = e.suppress
  onSetLockSelect: (e) -> @selectLocked = e.lock
  onLevelRestarted: (e) ->
    @selectLocked = false
    @selectSprite e, null

  onSelectSprite: (e) ->
    @selectThang e.thangID, e.spellName

  onCameraDragged: ->
    @dragged += 1

  onSpriteMouseUp: (e) ->
    return if key.shift #and @options.choosing
    return @dragged = 0 if @dragged > 3
    @dragged = 0
    sprite = if e.sprite?.thang?.isSelectable then e.sprite else null
    return if @flagCursorSprite and sprite?.thangType.get('name') is 'Flag'
    @selectSprite e, sprite

  onStageMouseDown: (e) ->
    return if key.shift #and @options.choosing
    @selectSprite e if e.onBackground

  selectThang: (thangID, spellName=null, treemaThangSelected = null) ->
    return @willSelectThang = [thangID, spellName] unless @sprites[thangID]
    @selectSprite null, @sprites[thangID], spellName, treemaThangSelected

  selectSprite: (e, sprite=null, spellName=null, treemaThangSelected = null) ->
    return if e and (@disabled or @selectLocked)  # Ignore clicks for selection/panning/wizard movement while disabled or select is locked
    worldPos = sprite?.thang?.pos
    worldPos ?= @camera.screenToWorld {x: e.originalEvent.rawX, y: e.originalEvent.rawY} if e?.originalEvent
    if worldPos and (@options.navigateToSelection or not sprite or treemaThangSelected) and e?.originalEvent?.nativeEvent?.which isnt 3
      @camera.zoomTo(sprite?.imageObject or @camera.worldToSurface(worldPos), @camera.zoom, 1000, true)
    sprite = null if @options.choosing  # Don't select sprites while choosing
    if sprite isnt @selectedSprite
      @selectedSprite?.selected = false
      sprite?.selected = true
      @selectedSprite = sprite
    alive = sprite and not (sprite.thang.health < 0)

    Backbone.Mediator.publish 'surface:sprite-selected',
      thang: if sprite then sprite.thang else null
      sprite: sprite
      spellName: spellName ? e?.spellName
      originalEvent: e
      worldPos: worldPos

    @willSelectThang = null if sprite  # Now that we've done a real selection, don't reselect some other Thang later.

    if alive and not @suppressSelectionSounds
      instance = sprite.playSound 'selected'
      if instance?.playState is 'playSucceeded'
        Backbone.Mediator.publish 'sprite:thang-began-talking', thang: sprite?.thang
        instance.addEventListener 'complete', ->
          Backbone.Mediator.publish 'sprite:thang-finished-talking', thang: sprite?.thang

  onFlagColorSelected: (e) ->
    @removeSprite @flagCursorSprite if @flagCursorSprite
    @flagCursorSprite = null
    for flagSprite in @spriteArray when flagSprite.thangType.get('name') is 'Flag'
      flagSprite.imageObject.cursor = if e.color then 'crosshair' else 'pointer'
    return unless e.color
    @flagCursorSprite = new FlagSprite @thangTypeFor('Flag'), @createSpriteOptions(thangID: 'Flag Cursor', color: e.color, team: me.team, isCursor: true, pos: e.pos)
    @addSprite @flagCursorSprite, @flagCursorSprite.thang.id, @spriteLayers['Floating']

  onFlagUpdated: (e) ->
    return unless e.active
    pendingFlag = new FlagSprite @thangTypeFor('Flag'), @createSpriteOptions(thangID: 'Pending Flag ' + Math.random(), color: e.color, team: e.team, isCursor: false, pos: e.pos)
    @addSprite pendingFlag, pendingFlag.thang.id, @spriteLayers['Floating']
    @pendingFlags.push pendingFlag

  onFlagAppeared: (e) ->
    # Remove the pending flag that matches this one's color/team/position, and any color/team matches placed earlier.
    t1 = e.sprite.thang
    pending = (@pendingFlags ? []).slice()
    foundExactMatch = false
    for i in [pending.length - 1 .. 0] by -1
      pendingFlag = pending[i]
      t2 = pendingFlag.thang
      matchedType = t1.color is t2.color and t1.team is t2.team
      matched = matchedType and (foundExactMatch or Math.abs(t1.pos.x - t2.pos.x) < 0.00001 and Math.abs(t1.pos.y - t2.pos.y) < 0.00001)
      if matched
        foundExactMatch = true
        @pendingFlags.splice(i, 1)
        @removeSprite pendingFlag
    e.sprite.imageObject.cursor = if @flagCursorSprite then 'crosshair' else 'pointer'
    null

  onRemoveSelectedFlag: (e) ->
    # Remove the selected sprite if it's a flag, or any flag of the given color if a color is given.
    flagSprite = _.find [@selectedSprite].concat(@spriteArray), (sprite) ->
      sprite and sprite.thangType.get('name') is 'Flag' and sprite.thang.team is me.team and (sprite.thang.color is e.color or not e.color) and not sprite.notOfThisWorld
    return unless flagSprite
    Backbone.Mediator.publish 'surface:remove-flag', color: flagSprite.thang.color

  # Marks

  updateSelection: ->
    if @selectedSprite?.thang and (not @selectedSprite.thang.exists or not @world.getThangByID @selectedSprite.thang.id)
      thangID = @selectedSprite.thang.id
      @selectedSprite = null  # Don't actually trigger deselection, but remove the selected sprite.
      @selectionMark?.toggle false
      @willSelectThang = [thangID, null]
    @updateTarget()
    return unless @selectionMark
    @selectedSprite = null if @selectedSprite and (@selectedSprite.destroyed or not @selectedSprite.thang)
    # The selection mark should be on the ground layer, unless we're not a normal sprite (like a wall), in which case we'll place it higher so we can see it.
    if @selectedSprite and @selectedSprite.imageObject.parent isnt @spriteLayers.Default
      @selectionMark.setLayer @spriteLayers.Default
    else if @selectedSprite
      @selectionMark.setLayer @spriteLayers.Ground
    @selectionMark.toggle @selectedSprite?
    @selectionMark.setSprite @selectedSprite
    @selectionMark.update()

  updateTarget: ->
    return unless @targetMark
    thang = @selectedSprite?.thang
    target = thang?.target
    targetPos = thang?.targetPos
    targetPos = null if targetPos?.isZero?()  # Null targetPos get serialized as (0, 0, 0)
    @targetMark.setSprite if target then @sprites[target.id] else null
    @targetMark.toggle @targetMark.sprite or targetPos
    @targetMark.update if targetPos then @camera.worldToSurface targetPos else null
