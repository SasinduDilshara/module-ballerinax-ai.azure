// Copyright (c) 2025 WSO2 LLC. (http://www.wso2.org).
//
// WSO2 Inc. licenses this file to you under the Apache License,
// Version 2.0 (the "License"); you may not use this file except
// in compliance with the License.
// You may obtain a copy of the License at
//
// http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing,
// software distributed under the License is distributed on an
// "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
// KIND, either express or implied.  See the License for the
// specific language governing permissions and limitations
// under the License.

import ballerina/http;
import ballerina/test;
import ballerinax/azure.openai.chat;
import ballerinax/azure.openai.embeddings;

# A lenient view of the chat completion request used by the mock service. The `messages` field is
# bound as `json[]` (rather than the strict `chatCompletionRequestMessage` union) so that multimodal
# content parts such as images and audio can be inspected without relying on union data binding.
type ChatCompletionTestRequest record {|
    # The sampling temperature, if sent by the connector.
    decimal? temperature?;
    # The upper bound for the number of generated tokens.
    int? max_completion_tokens?;
    # The conversation messages, kept as `json` to allow multimodal content inspection.
    json[] messages;
    # The tool definitions, if any.
    chat:chatCompletionTool[]? tools?;
    json...;
|};

service /llm on new http:Listener(8080) {
    resource function post azureopenai/deployments/gpt4onew/chat/completions(
            string api\-version, ChatCompletionTestRequest payload)
                returns chat:createChatCompletionResponse|error {
        test:assertEquals(api\-version, "2023-08-01-preview");
        test:assertEquals(payload?.temperature, DEFAULT_TEMPERATURE);
        test:assertEquals(payload?.max_completion_tokens, DEFAULT_MAX_TOKEN_COUNT);
        json message = payload.messages[0];

        json[]? content = check (check message.content).ensureType();
        if content is () {
            test:assertFail("Expected content in the payload");
        }

        TextContentPart initialTextContent = check content[0].fromJsonWithType();
        string initialText = initialTextContent.text.toString();
        test:assertEquals(content, getExpectedContentParts(initialText),
                string `Test failed for prompt with initial content, ${initialText}`);
        test:assertEquals(check message.role, "user");
        chat:chatCompletionTool[]? tools = payload?.tools;
        if tools is () || tools.length() == 0 {
            test:assertFail("No tools in the payload");
        }

        map<json>? parameters = check tools[0].'function?.parameters.toJson().cloneWithType();
        if parameters is () {
            test:assertFail("No parameters in the expected tool");
        }

        test:assertEquals(parameters, getExpectedParameterSchema(initialText),
                string `Test failed for prompt with initial content, ${initialText}`);
        return getTestServiceResponse(initialText);
    }

    // Simulates a GPT-5 (reasoning) deployment for the `generate` path. Such deployments only accept
    // the default sampling temperature. When the connector is configured with `temperature = ()` it
    // does not override the temperature, so the default value (1) defined by the chat client - which
    // is the only value these deployments accept - is sent, along with `max_completion_tokens`.
    resource function post azureopenai/deployments/gpt5mini/chat/completions(
            string api\-version, ChatCompletionTestRequest payload)
                returns chat:createChatCompletionResponse|error {
        test:assertEquals(api\-version, REASONING_API_VERSION);
        test:assertEquals(payload?.temperature, DEFAULT_REASONING_TEMPERATURE);
        test:assertEquals(payload?.max_completion_tokens, DEFAULT_MAX_TOKEN_COUNT);
        json message = payload.messages[0];
        json[]? content = check (check message.content).ensureType();
        if content is () {
            test:assertFail("Expected content in the payload");
        }
        TextContentPart initialTextContent = check content[0].fromJsonWithType();
        return getTestServiceResponse(initialTextContent.text.toString());
    }

    // Simulates a GPT-5 (reasoning) deployment for the `chat` path, verifying that the configured
    // `temperature` is omitted and the token limit is sent via `max_completion_tokens`.
    resource function post azureopenai/deployments/gpt5chat/chat/completions(
            string api\-version, ChatCompletionTestRequest payload)
                returns chat:createChatCompletionResponse {
        test:assertEquals(payload?.temperature, DEFAULT_REASONING_TEMPERATURE);
        test:assertEquals(payload?.max_completion_tokens, DEFAULT_MAX_TOKEN_COUNT);
        return {
            id: "test-id",
            'object: "chat.completion",
            created: 1234567890,
            model: "gpt-5",
            choices: [
                {
                    finish_reason: "stop",
                    index: 0,
                    logprobs: (),
                    message: {
                        role: "assistant",
                        refusal: (),
                        content: REASONING_MODEL_CHAT_RESPONSE
                    }
                }
            ]
        };
    }

    // Simulates a deployment that rejects a request parameter (for example, a non-default
    // `temperature` supplied to a GPT-5 reasoning deployment) with an HTTP 400 response. The
    // connector is expected to surface this error message back to the caller.
    resource function post azureopenai/deployments/gpt5error/chat/completions(
            string api\-version, ChatCompletionTestRequest payload) returns http:BadRequest =>
        {
            body: {
                "error": {
                    "message": PARAMETER_REJECTION_MESSAGE,
                    "type": "invalid_request_error",
                    "param": "temperature",
                    "code": "unsupported_value"
                }
            }
        };

    resource function post deployments/[string deploymentId]/embeddings(string api\-version, embeddings:Deploymentid_embeddings_body payload)
        returns embeddings:Inline_response_200|error {
        embeddings:Inline_response_200_data[] data = from int i in 0 ..< 2
            select {
                embedding: from int j in 0 ..< 1536
                    select 0.1 + j * 0.1,
                index: i,
                'object: "list"
            };
        return {
            data: payload.input is embeddings:InputItemsString[] ? data : [data[0]],
            model: "text-embedding-3-small",
            usage: {
                prompt_tokens: 15,
                total_tokens: 15
            },
            'object: "list"
        };
    }
}
