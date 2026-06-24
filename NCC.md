**Nation's Cup Clash**

Select a country and attempt to bring that nation to fame in the world's most intense soccer tournament. Sabotage your opponents before a match day. Give your team a relaxing day or declare the match a national holiday to boost crowd attendance. Come match day, enter the pitch and discover a tactical turn-based match where tactics triumph. Wins gain influence to repeat the process until your nation wins the Nation's Cup.

TODO:
* Get every country's colors which should be a maximum of 3 colors
  * Create away kits and home kits based on their country's colors which are used during matchday
  * The crowd should be a combination of each teams kits favoring the home team's kit
    * If it's world cup, the crowd shares the colors 50/50

* Overhaul the matchday scene and update the action turn results effects
  * Shots should reflect the outcome
    * A goal shakes the camera a little bit and zooms in behind the player before the shot. Then returns the camera to the previous position
    * A blocked shot should do similar but without the sparkling effect in goal
    * Add a popping up cartoon text effect wherever the block or goal happens. It should be a grow and shrink quickly. "GOAL!", "BLOCKED!", "SAVED!"
  * During the match when the user clicks continue, the animation of the players and ball should reflect the simulation of the stage where an opportunity isn't given
    * Mid field battle, no result just a small control and turn over
    * Single team control (Which team has control is influenced by their str versus the other team)
    * Goal kick to mid field
    * Throw-in to own end
    * Mid-field free kick because of red card
  * Flesh-out the entire stadium and instead of sharing a single half, switch sides when attacking versus defending.
  * When a turn starts, automatically select a player for the user to select an action. Once an action is selected for that player automatically move to the next player for the user.

* AI overhaul, we need to make the AI much more aggressive with a options for each difficulty.
  * Defense
    * Defender should attack the ball while maintaining position for the pass while at midrange. At close range, if close to the player it should attempt a tackle or decide to block shot by positioning itself in the way.
    * GK should always position itself favoring towards the near post.
  * Attack
    * Ball handler should attempt to make forward progression while the other attacker should attempt to get open while obeying offsides penalty. Ballhandler should make decision to pass move forward or shoot based on the best odds.
    * Before actions run out, it should always shoot. Always favor aggressive gameplay style.

* Add Google AdSense
  * Banner Ads at the side or bottom of the screen on a timer which transitions in every 2 minutes and stays for 1 minute in desktop mode
  * Matchday momentum boosters if they volunteer to watch an ad with a single matchday cooldown
    * Make match day boosters more effective. Create a better driver for watching them.
    * In desktop mode, this isn't possible, rather provide a large overlaying ad.
  * After a season, a large overlaying ad is shown to continue or new game.

* Make it multiplayer
  * Lobby where a user can either create session or join by code
    * Initial session setup has only a few parameters and can have an optional password. Creator can dictate the difficulty (hard by default), control how long each turn is max (15s - 60s)
  * Money is disabled
  * After a player selects their choice, all turns are processed concurrently. It's not wait for YOUR turn style.
  * When a player is knocked out from the game they go to spectator mode. Once match day starts for all players, spectators can tune into any match they want. Similarly, if a player chooses to simulate and the opponent chooses to play, the player who selected simulate is brought to spectator mode to watch the other player play and their own is AI. They can stop the simulation of their own team at any time (encourages them to play).
  * There are cases where a user may choose a nation in a group with very little teams so they have less matches and they would have a bye-week. In this event, when other players go to match day they can spectate while games are ongoing.
  * Ads work in a similar fashion.
    * If a user has ads removed they will automatically gain momentum plus a bonus to reward them during any ad break against an opponent.
  * If the user is waiting for other players to complete turns. A buffering wheel will appear to let them know what's going on.
  * If players finish a game before all other players are finished, they go to spectator mode.

* Add user Sign-In with Google
  * Campaign user saves
  * Remove ads with purchase
  * Multiplayer only available with sign-in, otherwise campaign is unable to save without sign-in

* Introduce unique buffs and sabotages for each nation. Requires heavy online research to make things feel unique.

* Provide a detailed writeup for all the various calculations and functions used to determine outcomes and buff and sabotages and such in "CALCULATIONS.md"

* Provide a detailed writeup for all the different components of the project in "NATIONSCUPCLASH.md"