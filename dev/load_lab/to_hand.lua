--- Menu -> first hand dealt, on a fixed seed. Run as a coroutine, one resume per frame, by both
--- Load Lab drivers. The path and the waits are the Pixel Lab tour's (`scenarios/tour.lua`), so
--- the two labs walk the same screens.
---
--- `lab.wait(seconds)` lets the game run; `lab.G` is the live game.
return function(lab)
    local MainMenuUI = require "main_menu_ui"
    local G = lab.G
    -- A returning player's menu: no tutorial strip, no discovery toasts. Same as the tour.
    if G.skip_tutorial then G:skip_tutorial() end
    require("milestone_queue").push = function() end
    G._milestone_active = nil

    MainMenuUI.open_page(G, "play")
    lab.wait(0.6)
    MainMenuUI.activate_menu_entry(G, "start")
    lab.wait(1.0)
    G._pending_run_seed = "LOADLAB"
    MainMenuUI._start_run(G)
    lab.wait(2.35)
    G:start_selected_blind()
    lab.wait(2.0)

    -- Fail loudly if the walk did not arrive: a trace of the wrong screen is not a measurement.
    assert(G.STATE == G.STATES.SELECTING_HAND,
        "load lab: expected SELECTING_HAND after the deal, got state " .. tostring(G.STATE))
    local cards = G.hand and G.hand.cards
    assert(type(cards) == "table" and #cards > 0, "load lab: no cards in hand after the deal")
end
