import ballerina/ai;
import ballerinax/azure.openai.chat;

type SchemaResponse record {|
    map<json> schema;
    boolean isOriginallyJsonObject = true;
|};

const JSON_CONVERSION_ERROR = "FromJsonStringError";
const CONVERSION_ERROR = "ConversionError";
const ERROR_MESSAGE = "Error occurred while attempting to parse the response from the " +
    "LLM as the expected type. Retrying and/or validating the prompt could fix the response.";
const RESULT = "result";
const GET_RESULTS_TOOL = "getResults";
const FUNCTION = "function";
const NO_RELEVANT_RESPONSE_FROM_THE_LLM = "No relevant response from the LLM";

isolated function generateJsonObjectSchema(map<json> schema) returns SchemaResponse {
    string[] supportedMetaDataFields = ["$schema", "$id", "$anchor", "$comment", "title", "description"];

    if schema["type"] == "object" {
        return {schema};
    }

    map<json> updatedSchema = map from var [key, value] in schema.entries()
        where supportedMetaDataFields.indexOf(key) is int
        select [key, value];

    updatedSchema["type"] = "object";
    map<json> content = map from var [key, value] in schema.entries()
        where supportedMetaDataFields.indexOf(key) !is int
        select [key, value];

    updatedSchema["properties"] = {[RESULT]: content};

    return {schema: updatedSchema, isOriginallyJsonObject: false};
}

isolated function parseResponseAsType(string resp,
        typedesc<anydata> expectedResponseTypedesc, boolean isOriginallyJsonObject) returns anydata|error {
    if !isOriginallyJsonObject {
        map<json> respContent = check resp.fromJsonStringWithType();
        anydata|error result = trap respContent[RESULT].fromJsonWithType(expectedResponseTypedesc);
        if result is error {
            return handleParseResponseError(result);
        }
        return result;
    }

    anydata|error result = resp.fromJsonStringWithType(expectedResponseTypedesc);
    if result is error {
        return handleParseResponseError(result);
    }
    return result;
}

isolated function getExpectedResponseSchema(typedesc<anydata> expectedResponseTypedesc) returns SchemaResponse {
    // Restricted at compile-time for now.
    typedesc<json> td = checkpanic expectedResponseTypedesc.ensureType();
    return generateJsonObjectSchema(generateJsonSchemaForTypedescAsJson(td));
}

isolated function getGetResultsToolChoice() returns chat:ChatCompletionNamedToolChoice => {
        'type: FUNCTION,
        'function: {
            name: GET_RESULTS_TOOL
        }
    };

isolated function getGetResultsTool(map<json> parameters) returns chat:ChatCompletionTool[]|error {
    return [{
        'type : FUNCTION,
        'function: {
            name: GET_RESULTS_TOOL,
            parameters: check parameters.cloneWithType(),
            description: "Tool to call with the resp onse from a large language model (LLM) for a user prompt."
        }
    }];
}

isolated function gnerateChatCreationContent(ai:Prompt prompt) returns string {
    string str = prompt.strings[0];
    anydata[] insertions = prompt.insertions;
    foreach int i in 0 ..< insertions.length() {
        anydata value = insertions[i];
        string promptStr = prompt.strings[i + 1];

        if value is ai:TextDocument {
            str = str + value.content + promptStr;
            continue;
        }
        str = str + value.toString() + promptStr;
    }
    return str.trim();
}

isolated function handleParseResponseError(error chatResponseError) returns error {
    if chatResponseError.message().includes(JSON_CONVERSION_ERROR)
            || chatResponseError.message().includes(CONVERSION_ERROR) {
        return error(string `${ERROR_MESSAGE}`, detail = chatResponseError);
    }
    return chatResponseError;
}

isolated function generateLlmResponse(chat:Client llmClient, string deploymentId, 
        string apiVersion, ai:Prompt prompt, typedesc<json> expectedResponseTypedesc) returns anydata|error {
    string content = gnerateChatCreationContent(prompt);
    SchemaResponse schemaResponse = getExpectedResponseSchema(expectedResponseTypedesc);
    chat:CreateChatCompletionRequest request = {
        messages: [
            {
                role: ai:USER,
                "content": content
            }
        ], 
        tools: check getGetResultsTool(schemaResponse.schema),
        tool_choice: getGetResultsToolChoice()
    };

    chat:CreateChatCompletionResponse|error response =
        llmClient->/deployments/[deploymentId]/chat/completions.post(apiVersion, request);
    if response is error {
        return error ai:LlmError("LLM call failed: " + response.message());
    }

    record {|
        chat:ChatCompletionResponseMessage message?;
        chat:ContentFilterChoiceResults content_filter_results?;
        int index?;
        string finish_reason?;
        anydata...;
    |}[]? choices = response.choices;

    if choices is () || choices.length() == 0 {
        return error ai:LlmError("No completion choices");
    }

    chat:ChatCompletionResponseMessage? message = choices[0].message;
    chat:ChatCompletionMessageToolCall[]? toolCalls = message?.tool_calls;
    if toolCalls is () || toolCalls.length() == 0 {
        return error ai:LlmError(NO_RELEVANT_RESPONSE_FROM_THE_LLM);
    }

    chat:ChatCompletionMessageToolCall tool = toolCalls[0];
    map<json>|error arguments = tool.'function.arguments.fromJsonStringWithType();
    if arguments is error {
        return error ai:LlmError(NO_RELEVANT_RESPONSE_FROM_THE_LLM);
    }

    anydata res = check parseResponseAsType(arguments.toJsonString(), expectedResponseTypedesc, 
                            schemaResponse.isOriginallyJsonObject);
    anydata|error result = res.ensureType(expectedResponseTypedesc);

    if result is error {
        return error(string `Invalid value returned from the LLM Client, expected: '${
            expectedResponseTypedesc.toBalString()}', found '${(typeof response).toBalString()}'`);
    }
    return result;
}
