/*
 * Copyright (C) 2020 LogicMonitor, Inc.
 *
 * Licensed under the Apache License, Version 2.0 (the "License"); you may not use this file except
 * in compliance with the License. You may obtain a copy of the License at
 *
 * http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software distributed under the License
 * is distributed on an "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express
 * or implied. See the License for the specific language governing permissions and limitations under
 * the License.
 */

package com.logicmonitor.logs.azure;

import java.time.Instant;
import java.util.List;
import java.util.Optional;
import java.util.function.Function;
import java.util.regex.Pattern;
import java.util.regex.PatternSyntaxException;
import java.util.stream.Collectors;
import java.util.stream.Stream;
import java.util.stream.StreamSupport;
import com.google.gson.Gson;
import com.google.gson.GsonBuilder;
import com.google.gson.JsonElement;
import com.google.gson.JsonObject;
import com.logicmonitor.logs.model.LogEntry;

/**
 * Transforms one JSON object into one or multiple log entries.<br>
 * The following formats are supported:
 * <ul>
 * <li> single log event
 * <li> {@value #AZURE_RECORDS_PROPERTY} = array of log events
 * </ul>
 */
public class LogEventAdapter implements Function<JsonObject, List<LogEntry>> {
    /**
     * Name of the JSON property containing array of log events.
     */
    public static final String AZURE_RECORDS_PROPERTY = "records";
    /**
     * Name of the LM property used to match the resources.
     */
    public static final String LM_RESOURCE_PROPERTY = "system.azure.resourceid";

    /**
     * GSON instance.
     */
    private static final Gson GSON = new GsonBuilder().create();

    private final Pattern scrubPattern;

    public LogEventAdapter(String regexScrub) throws PatternSyntaxException {
        if (regexScrub != null) {
            scrubPattern = Pattern.compile(regexScrub);
        } else {
            scrubPattern = null;
        }
    }

    /**
     * Gets the regex pattern used to scrub log messages.
     * @return the pattern object
     */
    protected Pattern getScrubPattern() {
        return scrubPattern;
    }

    /**
     * Applies the log transformation.
     * @param log Azure log event
     * @return list of log entries
     */
    @Override
    public List<LogEntry> apply(JsonObject log) {
        // if the JSON object contains "records" array, transform its members
        return Optional.ofNullable(log.get(AZURE_RECORDS_PROPERTY))
            .filter(JsonElement::isJsonArray)
            .map(JsonElement::getAsJsonArray)
            .map(records -> StreamSupport.stream(records.spliterator(), true)
                .filter(JsonElement::isJsonObject)
                .map(JsonElement::getAsJsonObject)
            )
            .orElseGet(() -> Stream.of(log))
            .map(this::createEntry)
            .collect(Collectors.toList());
    }

    /**
     * Transforms single Azure log object into log entry.
     * @param json the log object
     * @return log entry
     */
    protected LogEntry createEntry(JsonObject json) {
        LogEventMessage event = GSON.fromJson(json, LogEventMessage.class);
        LogEntry entry = new LogEntry();

        // resource ID
        entry.putLmResourceIdItem(LM_RESOURCE_PROPERTY, event.getResourceId());

        // timestamp as epoch
        Optional.of(event.getTime())
            .map(Instant::parse)
            .map(Instant::getEpochSecond)
            .ifPresent(entry::setTimestamp);

        // message: properties.Msg if present, otherwise the whole JSON
        String message;
        if (event.getProperties().getMsg() != null) {
            message = event.getProperties().getMsg();
        } else {
            message = GSON.toJson(json);
        }

        if (scrubPattern != null) {
            message = scrubPattern.matcher(message).replaceAll("");
        }
        entry.setMessage(message);

        return entry;
    }

}
