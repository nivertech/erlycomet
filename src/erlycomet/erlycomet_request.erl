%%%-------------------------------------------------------------------
%%% @author    Roberto Saccon <rsaccon@gmail.com> [http://rsaccon.com]
%%% @author    Tait Larson
%%% @copyright 2007 Roberto Saccon, Tait Larson
%%% @doc Comet extension for MochiWeb
%%% @reference  See <a href="http://erlyvideo.googlecode.com" target="_top">http://erlyvideo.googlecode.com</a> for more information
%%% @end  
%%%
%%% The MIT License
%%%
%%% Copyright (c) 2007 Roberto Saccon, Tait Larson
%%%
%%% Permission is hereby granted, free of charge, to any person obtaining a copy
%%% of this software and associated documentation files (the "Software"), to deal
%%% in the Software without restriction, including without limitation the rights
%%% to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
%%% copies of the Software, and to permit persons to whom the Software is
%%% furnished to do so, subject to the following conditions:
%%%
%%% The above copyright notice and this permission notice shall be included in
%%% all copies or substantial portions of the Software.
%%%
%%% THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
%%% IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
%%% FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
%%% AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
%%% LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
%%% OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
%%% THE SOFTWARE.
%%%
%%% @since 2007-11-11 by Roberto Saccon, Tait Larson
%%%-------------------------------------------------------------------
-module(erlycomet_request).
-author('telarson@gmail.com').
-author('rsaccon@gmail.com').


%% API
-export([handle/2]).

-record(state, {id = undefined,
                connection_type,
				events = [],
				timeout = 1200000,      %% 20 min, just for testing
				callback = undefined}).  


%%====================================================================
%% API
%%====================================================================
%%--------------------------------------------------------------------
%% @spec
%% @doc handle POST / GET Comet messages
%% @end 
%%--------------------------------------------------------------------
handle(Req, 'POST') ->
	handle(Req, Req:parse_post());
	
handle(Req, 'GET') ->
	handle(Req, Req:parse_qs());	

handle(Req, [{"message", Msg}, {"jsonp", Callback} | _]) ->
	case process_bayeux_msg(Req, mochijson:decode(Msg), Callback) of
		done ->
			ok;
		{array,[done]} ->
			ok;
		Body ->
		    Resp = callback_wrapper(mochijson:encode(Body), Callback),
			Req:ok({"text/javascript", Resp})   
	end;
    	
handle(Req, [{"message", Msg} | _]) ->
	case process_bayeux_msg(Req, mochijson:decode(Msg), undefined) of
		done ->
			ok;
		{array,[done]} ->
			ok;
		Body ->
			Req:ok({"text/json", mochijson:encode(Body)})   
	end;
    	
handle(Req, _) ->
	Req:not_found().


%%====================================================================
%% Internal functions
%%====================================================================

%% input: json object. output: json object result of message processing.
process_bayeux_msg(Req, {Type, Content}=Struct, Callback) ->
    case Type of
	    array  -> 
		    {array, [ process_msg(Req, M, Callback) || M <- Content ]};
	    struct -> 
		    %{array, [ process_msg(Req, Msgs) ]}  ???????????
			process_msg(Req, Struct, Callback)
    end.


process_msg(Req, Struct, Callback) ->
	 process_cmd(Req, get_bayeux_val("channel", Struct), Struct, Callback).


get_bayeux_val(Key, {struct, Pairs}) when is_list(Pairs) ->
	case [ V || {K, V} <- Pairs, K =:= Key] of
		[] ->
			undefined;
		[ V | _Rest ] ->
    		V
    end;
get_bayeux_val(_, _) ->
	undefined.


process_cmd(_Req, "/meta/handshake", _Struct, _) ->	
	% Advice = {struct, [{reconnect, "retry"},
    %                   {interval, 5000}]},
    Resp = [{channel, "/meta/handshake"}, 
            {version, 1.0},
            {supportedConnectionTypes, {array, ["long-polling",
												"callback-polling"]}},
            {clientId, generate_id()},
            {successful, true}],
    % Resp2 = [{advice, Advice} | Resp],
    {struct, Resp};

process_cmd(Req, "/meta/connect", Struct, Callback) ->	
    ClientId = get_bayeux_val("clientId", Struct),
    ConnectionType = get_bayeux_val("connectionType", Struct),
	L = [{"channel", "/meta/connect"}, 
         {"clientId", ClientId}],    
    case erlycomet_api:replace_connection(ClientId, self()) of
        {ok, new} ->
           {struct, [{"successful", true} | L]};
	    {ok, replaced} ->	
            Msg = {struct, [{"successful", true} | L]},
	        Resp = Req:respond({200, [], chunked}),
	        loop(Resp, #state{id = ClientId, 
	                          connection_type = ConnectionType,
	                          events = [Msg],
	                          callback = Callback});
	    _ ->
        	{struct, [{"successful", false} | L]}
    end;
	
process_cmd(Req, "/meta/disconnect", Struct, _) ->	
    ClientId = get_bayeux_val("clientId", Struct),
    process_cmd2(Req, "/meta/disconnect", ClientId);

process_cmd(Req, "/meta/subscribe", Struct, _) ->	
    ClientId = get_bayeux_val("clientId", Struct),
	Subscription = get_bayeux_val("subscription", Struct),
	process_cmd2(Req, "/meta/subscribe", ClientId, Subscription);
	
process_cmd(Req, "/meta/unsubscribe", Struct, _) ->	
    ClientId = get_bayeux_val("clientId", Struct),
	Subscription = get_bayeux_val("subscription", Struct),
	process_cmd2(Req, "/meta/unsubscribe", ClientId, Subscription);	
	
process_cmd(Req, Channel, Struct, _) ->
    ClientId = get_bayeux_val("clientId", Struct),
    Data = get_bayeux_val("data", Struct),
	process_cmd2(Req, Channel, ClientId, Data).   
    
    
process_cmd2(_, Channel, undefined) ->	
    {struct, [{"channel", Channel}, {"successful", false}]};
             	
process_cmd2(_Req, "/meta/disconnect", ClientId) ->	
	L = [{"channel", "/meta/disconnect"}, 
         {"clientId", ClientId}],
    case erlycomet_api:remove_connection(ClientId) of
	    ok -> {struct, [{"successful", true}  | L]};
  	    _ ->  {struct, [{"successful", false}  | L]}
	end. 
    	
process_cmd2(_, Channel, undefined, _) ->	
    {struct, [{"channel", Channel}, {"successful", false}]};
                  
process_cmd2(_Req, "/meta/subscribe", ClientId, Subscription) ->	
	L = [{"channel", "/meta/subscribe"}, 
         {"clientId", ClientId},
         {"subscription", Subscription}],
    case erlycomet_api:subscribe(ClientId, Subscription) of
	    ok -> {struct, [{"successful", true}  | L]};
  	    _ ->  {struct, [{"successful", false}  | L]}
	end;	
	
process_cmd2(_Req, "/meta/unsubscribe", ClientId, Subscription) ->	
	L = [{"channel", "/meta/unsubscribe"}, 
         {"clientId", ClientId},
         {"subscription", Subscription}],          
    case erlycomet_api:unsubscribe(ClientId, Subscription) of
	    ok -> {struct, [{"successful", true}  | L]};
  	    _ ->  {struct, [{"successful", false}  | L]}
	end;

process_cmd2(_Req, Channel, ClientId, Data) ->	
    L = [{"channel", Channel}, 
         {"clientId", ClientId}],
    case erlycomet_api:deliver_to_channel(Channel, Data) of
        ok -> {struct, [{"successful", true}  | L]};
        _ ->  {struct, [{"successful", false}  | L]}
    end.
    	
callback_wrapper(Data, undefined) ->
    Data;		
callback_wrapper(Data, Callback) ->
    lists:concat([Callback, "(", Data, ");"]).
    
    			
generate_id() ->
    <<Num:128>> = crypto:rand_bytes(16),
    [HexStr] = io_lib:fwrite("~.16B",[Num]),
    case erlycomet_api:connection(HexStr) of
        undefined ->
            HexStr;
     _ ->
        generate_id()
    end.


loop(Resp, #state{events=Events, id=Id, callback=Callback} = State) ->
    receive
        stop ->  
            disconnect(Resp, Id, State);
        {add, Event} -> 
    		loop(Resp, State#state{events=[Event | Events]});      
        {flush, Event} -> 
        	Events2 = lists:reverse([Event | Events]),
        	send(Resp, Events2, Callback),
        	done;    		     
        flush -> 
            Events2 = lists:reverse(Events),
            send(Resp, Events2, Callback),
			done 
	after State#state.timeout ->
		disconnect(Resp, Id, Callback)
    end.


send(Resp, Events, Callback) ->
	Chunk = callback_wrapper(mochijson:encode({array, Events}), Callback),
    Resp:write_chunk(Chunk),
    Resp:write_chunk([]).

    
disconnect(Resp, Id, Callback) ->
	erlycomet_api:remove_connection(Id),
	Msg = {struct, [{"channel", "/meta/disconnect"}, 
                    {"successful", true},
                    {"clientId", Id}]},
    Chunk = callback_wrapper(mochijson:encode(Msg), Callback),
    Resp:write_chunk(Chunk),
	Resp:write_chunk([]),
	done.