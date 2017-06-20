%% -------------------------------------------------------------------
%%
%% Copyright (c) 2017 Carlos Gonzalez Florido.  All Rights Reserved.
%%
%% This file is provided to you under the Apache License,
%% Version 2.0 (the "License"); you may not use this file
%% except in compliance with the License.  You may obtain
%% a copy of the License at
%%
%%   http://www.apache.org/licenses/LICENSE-2.0
%%
%% Unless required by applicable law or agreed to in writing,
%% software distributed under the License is distributed on an
%% "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
%% KIND, either express or implied.  See the License for the
%% specific language governing permissions and limitations
%% under the License.
%%
%% -------------------------------------------------------------------

-ifndef(NKEVENT_HRL_).
-define(NKEVENT_HRL_, 1).

%% ===================================================================
%% Defines
%% ===================================================================


-record(nkevent, {
    srv_id = any :: nkevent:srv_id(),
    class :: nkevent:class(),
    subclass = <<>> :: nkevent:subclass(),
    type = <<>> :: nkevent:type() | [nkevent:type()],
    domain = <<>> :: nkevent:domain(),
    obj_id = <<>> :: nkevent:obj_id(),
    body = #{} :: nkevent:body(),
    pid = undefined :: pid() | undefined,
    debug = false :: boolean(),
    meta = #{} :: map()
}).


%% ===================================================================
%% Records
%% ===================================================================




-endif.

