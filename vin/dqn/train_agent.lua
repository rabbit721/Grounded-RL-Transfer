
require 'xlua'
require 'optim'
require 'sys'

require 'image'
local visdom = require 'visdom'
visdom.ipv6 = false
print(visdom.ipv6)
local plot = visdom{server = 'http://localhost', port = 8097}

local cmd = torch.CmdLine()
cmd:text()
cmd:text('Train Agent in Environment:')
cmd:text()
cmd:text('Options:')

cmd:option('-framework', '', 'name of training framework')
cmd:option('-env', '', 'name of environment to use')
cmd:option('-game_path', '', 'path to environment file (ROM)')
cmd:option('-env_params', '', 'string of environment parameters')
cmd:option('-pool_frms', '',
           'string of frame pooling parameters (e.g.: size=2,type="max")')
cmd:option('-actrep', 1, 'how many times to repeat action')
cmd:option('-random_starts', 0, 'play action 0 between 1 and random_starts ' ..
           'number of times at the start of each training episode')

cmd:option('-name', '', 'filename used for saving network and training history')
cmd:option('-network', '', 'reload pretrained network')
cmd:option('-agent', '', 'name of agent file to use')
cmd:option('-agent_params', '', 'string of agent parameters')
cmd:option('-seed', 1, 'fixed input seed for repeatable experiments')
cmd:option('-saveNetworkParams', false,
           'saves the agent network in a separate file')
cmd:option('-prog_freq', 5*10^3, 'frequency of progress output')
cmd:option('-save_freq', 5*10^4, 'the model is saved every save_freq steps')
cmd:option('-eval_freq', 10^4, 'frequency of greedy evaluation')
cmd:option('-save_versions', 0, '')

cmd:option('-steps', 10^5, 'number of training steps to perform')
cmd:option('-eval_steps', 10^5, 'number of evaluation steps')
cmd:option('-eval_episodes', 10, 'number of evaluation episodes')

cmd:option('-verbose', 2,
           'the higher the level, the more information is printed to screen')
cmd:option('-threads', 1, 'number of BLAS threads')
cmd:option('-gpu', -1, 'gpu flag')
cmd:option('-zmq_port', 6000, 'ZMQ port')
cmd:option('-game_num', "0", 'IDs of the games to be played')
cmd:option('-test_game_num', "0", 'IDs of the games to test on')
cmd:option('-level_num', "0", 'IDs of the levels to be played')
cmd:option('-test_level_num', "0", 'IDs of the levels to test on')
cmd:option('-exp_folder', 'logs/', 'folder for logs')
cmd:option('-num_actions', 4, 'number of available actions')
cmd:option('-plot', false, 'set true to plot using visdom')
cmd:option('-frame_collect', false, 'set true to collect frames from gameplay')
--cmd:option('-pretrained_embeddings', 'vectors/vectors_wiki.20.txt', 'path to pretained word embeddings')
cmd:option('-pretrained_embeddings', '', 'path to pretained word embeddings')
cmd:option('-text_fraction', 1, 'fraction of text to ingest')

cmd:text()


local opt = cmd:parse(arg)

TEXT_FRACTION = opt.text_fraction

if not dqn then
    require "initenv"
end


--- General setup.
local game_ids, test_game_ids, level_ids, test_level_ids, game_env, game_actions, agent, opt = setup(opt)

-- override print to always flush the output
-- local old_print = print
-- local print = function(...)
--     old_print(...)
--     io.flush()
-- end



local learn_start = agent.learn_start
local start_time = sys.clock()
local reward_counts = {}
local episode_counts = {}
local time_history = {}
local v_history = {}
local qmax_history = {}
local td_history = {}
local reward_history = {}
local step = 0
time_history[1] = 0

local total_reward
local nrewards
local nepisodes
local episode_reward
local game_counter = 1
local test_game_counter = 1
local level_counter = 1
local test_level_counter = 1

local r_plot, q_plot
if opt.plot then
  r_plot = plot:line{X=torch.zeros(2), Y = torch.zeros(2), options={title=opt.exp_folder .. " Reward"}}
  q_plot = plot:line{X=torch.zeros(2), Y = torch.zeros(2), options={title=opt.exp_folder .. " Q"}}
end

function increment_counter(test)
    if not test then
        agent.current_game = game_ids[game_counter]; 
        agent.current_level = level_ids[level_counter];
        level_counter = level_counter + 1    
        if level_counter > (#level_ids) then
            level_counter = 1
            game_counter = (game_counter)%(#game_ids)+1;
        end
    else
        agent.current_game = test_game_ids[test_game_counter]; 
        agent.current_level = test_level_ids[test_level_counter];
        test_level_counter = test_level_counter + 1    
        if test_level_counter > (#test_level_ids) then
            test_level_counter = 1
            test_game_counter = (test_game_counter)%(#test_game_ids)+1;
        end
    end
end



local screen, reward, terminal = game_env:newGame(game_ids[game_counter], level_ids[level_counter]); increment_counter()

print("Iteration ..", step)
local win = nil

local frame_collector = {}

while step < opt.steps do

    -- sys.sleep(0.1)
    xlua.progress(step, opt.steps)

    step = step + 1
    local action_index = agent:perceive(reward, screen, terminal)

    -- game over? get next game!
    if not terminal then
        screen, reward, terminal = game_env:step(game_actions[action_index])
    else
        -- TODO(karthik): need for random starts?
        screen, reward, terminal = game_env:newGame(game_ids[game_counter], level_ids[level_counter]); increment_counter()
    end

    if opt.frame_collect then
        table.insert(frame_collector, {screen=screen, game=game_ids[game_counter], level=level_ids[level_counter]})
    end

    -- display screen
    -- win = image.display({image=screen, win=win})

    if step % opt.prog_freq == 0 then
        assert(step==agent.numSteps, 'trainer step: ' .. step ..
                ' & agent.numSteps: ' .. agent.numSteps)
        print("Steps: ", step)
        agent:report()
        print("Loss (when training using expert teacher): ", agent.loss/agent.loss_cnt)
        agent.loss = 0 
        agent.loss_cnt = 0
        collectgarbage()
    end

    if step%1000 == 0 then collectgarbage() end

    if step % opt.eval_freq == 0 and step > learn_start then
        -- Play out current game.
        while not terminal do
            screen, reward, terminal = game_env:step(0)
        end 

        
        -- Logging.
        test_avg_Q = test_avg_Q or optim.Logger(paths.concat(opt.exp_folder , 'test_avgQ.log'))
        test_avg_R = test_avg_R or optim.Logger(paths.concat(opt.exp_folder , 'test_avgR.log'))   

        total_reward = 0
        nrewards = 0
        nepisodes = 0
        episode_reward = 0

        local eval_time = sys.clock()
        for ep_num=1, opt.eval_episodes do
            xlua.progress(ep_num, opt.eval_episodes)
    
            -- Start new game.
            screen, reward, terminal = game_env:newGame(test_game_ids[test_game_counter], test_level_ids[test_level_counter]); increment_counter(true)

            for estep=1,opt.eval_steps do

                if estep%1000 == 0 then collectgarbage() end

                -- record every reward
                episode_reward = episode_reward + reward
                if reward ~= 0 then
                   nrewards = nrewards + 1
                end

                if terminal then
                    total_reward = total_reward + episode_reward
                    episode_reward = 0
                    nepisodes = nepisodes + 1
                    break
                end

                local action_index = agent:perceive(reward, screen, terminal, true, 0.05)

                -- Play game in test mode (episodes don't end when losing a life)
                screen, reward, terminal = game_env:step(game_actions[action_index])

                -- display screen
                -- win = image.display({image=screen, win=win})                
            end

            -- Play out current game, if existing. Just as precaution. 
            -- opt.eval_steps should be large enough to allow episode completion.
            while not terminal do
                screen, reward, terminal = game_env:step(0)
            end 
        end

        -- Start a new game for the next training episode. 
        screen, reward, terminal = game_env:newGame(game_ids[game_counter], level_ids[level_counter]); increment_counter()

        print("Total reward, num_eps: ", total_reward, nepisodes)
        

        eval_time = sys.clock() - eval_time
        start_time = start_time + eval_time
        agent:compute_validation_statistics()
        local ind = #reward_history+1
        total_reward = total_reward/math.max(1, nepisodes)

        if #reward_history == 0 or total_reward > torch.Tensor(reward_history):max() then
            agent.best_network = agent.network:clone()
        end

        if agent.v_avg then
            v_history[ind] = agent.v_avg
            td_history[ind] = agent.tderr_avg
            qmax_history[ind] = agent.q_max
        end
        print("V", v_history[ind], "TD error", td_history[ind], "Qmax", qmax_history[ind])

        -- Plotting graphs.
        test_avg_R:add{['Average Reward'] = total_reward}
        test_avg_Q:add{['Average Q'] = agent.v_avg}
     
        test_avg_R:style{['Average Reward'] = '-'}; 
        test_avg_Q:style{['Average Q'] = '-'};
        
        if opt.plot then
          plot:line{X = torch.ones(1) * step,
                      Y = torch.ones(1) * total_reward,
                      win = r_plot,
                     update='append'}
          plot:line{X = torch.ones(1) * step,
                      Y = torch.ones(1) * agent.v_avg,
                      win = q_plot,
                     update='append'}
        end
         

        reward_history[ind] = total_reward
        reward_counts[ind] = nrewards
        episode_counts[ind] = nepisodes

        time_history[ind+1] = sys.clock() - start_time

        local time_dif = time_history[ind+1] - time_history[ind]

        local training_rate = opt.actrep*opt.eval_freq/time_dif

        print(string.format(
            '\nSteps: %d (frames: %d), reward: %.2f, epsilon: %.2f, lr: %G, ' ..
            'training time: %ds, training rate: %dfps, testing time: %ds, ' ..
            'testing rate: %dfps,  num. ep.: %d,  num. rewards: %d',
            step, step*opt.actrep, total_reward, agent.ep, agent.lr, time_dif,
            training_rate, eval_time, opt.actrep*opt.eval_steps/eval_time,
            nepisodes, nrewards))
    end

    if step % opt.save_freq == 0 or step == opt.steps then
        local s, a, r, s2, term = agent.valid_s, agent.valid_a, agent.valid_r,
            agent.valid_s2, agent.valid_term
        agent.valid_s, agent.valid_a, agent.valid_r, agent.valid_s2,
            agent.valid_term = nil, nil, nil, nil, nil, nil, nil
        local w, dw, g, g2, delta, delta2, deltas, tmp = agent.w, agent.dw,
            agent.g, agent.g2, agent.delta, agent.delta2, agent.deltas, agent.tmp
        agent.w, agent.dw, agent.g, agent.g2, agent.delta, agent.delta2,
            agent.deltas, agent.tmp = nil, nil, nil, nil, nil, nil, nil, nil

        local filename = opt.name
        if opt.save_versions > 0 then
            filename = filename .. "_" .. math.floor(step / opt.save_versions)
        end
        filename = filename
        torch.save(filename .. ".t7", {agent = agent,
                                model = agent.network:clone():float(),
                                best_model = agent.best_network:clone():float(),
                                text = agent.text,  -- Store word mappings for text files.
                                word_to_int = agent.word_to_int,
                                word_index = agent.word_index,
                                reward_history = reward_history,
                                reward_counts = reward_counts,
                                episode_counts = episode_counts,
                                time_history = time_history,
                                v_history = v_history,
                                td_history = td_history,
                                qmax_history = qmax_history,
                                arguments=opt})

	    -- save frames. 
        if opt.frame_collect then
	        torch.save(filename .. "_frames_" .. step .. ".t7", frame_collector)
	        frame_collector = {}
        end

        if opt.saveNetworkParams then
            local nets = {network=w:clone():float()}
            torch.save(filename..'.params.t7', nets, 'ascii')
        end
        agent.valid_s, agent.valid_a, agent.valid_r, agent.valid_s2,
            agent.valid_term = s, a, r, s2, term
        agent.w, agent.dw, agent.g, agent.g2, agent.delta, agent.delta2,
            agent.deltas, agent.tmp = w, dw, g, g2, delta, delta2, deltas, tmp
        print('Saved:', filename .. '.t7')
        io.flush()
        collectgarbage()
    end
end
