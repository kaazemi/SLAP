function dataset = AlignScanImageData8Stim(dataset,optsin)
%default options:
    opts.motionChan = 1;
    opts.activityChan = [1 2];  tooltips.activityChan = 'activity channels, e.g. [1 2] or [1]';
    opts.preFrames = 4;  tooltips.preFrames = '4 for allrecent datasets; 1 for datasets acquired before 2017-10-01';
    opts.threshDense = true; tooltips.threshDense = 'Set intensity thresholds for dense imaging?';
    opts.doCensor = true; tooltips.doCensor = 'Censor Motion?';
    opts = optionsGUI(opts, tooltips);
    
    opts.forceStage = false(1, 100);
if ~nargin
    disp('Starting Stage 1:')
    %get a list of movies
    [fns, dr] = uigetfile('*.tif', 'Select SI Activity movies', 'MultiSelect', 'On');
    if ~iscell(fns)
        fns = {fns};
    end
    drsave = dr;
    fnsave = [fns{1}(1:end-16) '_rasterDataset'];
    
    phaseChan = opts.motionChan; %channel to use for phase correction
        
    %LOAD STIMULUS
    stimfiles = dir([dr  filesep '..' filesep '*Timings*']);
    if ~isempty(stimfiles)
        stimList = [];
        for sf = 1:length(stimfiles)
            SF = load([dr filesep '..' filesep stimfiles(sf).name]);
            stimList = [stimList ; SF.time_stamp]; %#ok<AGROW>
        end
    else
        error('no timing files in folder');
    end
    
    %for each movie, perform bidi phase correction
    for fnum = 1:length(fns)
        disp(['Loading and Phase-correcting file: ' int2str(fnum) ' of ' int2str(length(fns))])
        
        reader = ScanImageTiffReader([dr filesep fns{fnum}]);
        IM = permute(double(reader.data()), [2 1 3]);

        if fnum==1
            dataset.fns = fns;
            dataset.metadata = parseMetaData(reader.metadata());
            dataset.nChan= length(dataset.metadata.hChannels.channelSave);
            dataset.IM = nan(size(IM,1), size(IM,2), size(IM,3)/dataset.nChan, dataset.nChan, length(fns), 'single');
        end
        
        phaseOffset = findPhase(IM(:,:,phaseChan:dataset.nChan:end)); %find phase with channel 1
        for ch = 1:dataset.nChan
            dataset.IM(:,:,:,ch, fnum) = fixPhase(IM(:,:,ch:dataset.nChan:end), phaseOffset);
        end
        
        %stimulus timing
        desc = reader.descriptions();
        ix = strfind(desc{1},  'epoch = ');
        eval([desc{1}(ix:end-1) ';']);
        dataset.stimTime(fnum) = datenum(epoch);
        dataset.frameTimes(fnum,1:length(desc)/2) = nan;
        for ii = 1:length(desc)/2
            ix = strfind(desc{2*ii},  'frameTimestamps_sec =');
            dataset.frameTimes(fnum, ii) = str2double(desc{2*ii}(ix+22:ix+29));
        end
    end
    
    %Identify stimulus identities
    %dataset.stimtime is the start of the acquisition as recorded on the
    %imaging computer
    %stimList(:,1) is a list of all stimulus trigger times
    
    
    %assuming that the clocks of the two computers are within 5 min of each
    %other...
    candidates = find(abs(stimList(:,1)-dataset.stimTime(1))<0.01);
    V = nan(1,length(candidates));
    for c_ix = 1:length(candidates)
        offset = stimList(candidates(c_ix),1)-dataset.stimTime(1);
        Mo = stimList(:,1) - (dataset.stimTime+offset);
        V(c_ix) = var(min(abs(Mo),[],1));
    end
    [minVal, bestCandidate] = min(conv(V, ones(1,8), 'valid'));
    if minVal>1e-9
        keyboard %did not find the minimum properly
    end
    %so the best delay is...
    dataset.stimulus.stimDelay = stimList(candidates(bestCandidate),1)-dataset.stimTime(1);
    
    dataset.stimulus.stim = nan(length(fns), 8);
    for fnum = 1:length(fns)
        %find the earlier sequence of 8 stimuli that starts very close to this time
        [~, minix] = min(abs(stimList(:,1) -dataset.stimTime(fnum) - dataset.stimulus.stimDelay));
        listIXs = max(1, minix-2):min(size(stimList,1), minix+9);
        ss = diff(stimList(listIXs,1)); spacing = median(ss);
        [~,ord] = min(conv(abs(ss-spacing), ones(1,7), 'valid'));
        stimIx = listIXs(ord);
        [dataset.stimulus.timeError(fnum), ~] = min(abs(dataset.stimTime(fnum) - stimList(:,1) + dataset.stimulus.stimDelay));
        
        dataset.stimulus.stim(fnum, 1:8) = stimList(stimIx:stimIx+7,2);
        dataset.stimulus.stimTime(fnum, 1:8) = stimList(stimIx:stimIx+7,1);
        dataset.stimulus.stimTime(fnum, 1:8) = (86400.0 *(dataset.stimulus.stimTime(fnum, 1:8)- dataset.stimulus.stimTime(fnum, 1)));
        dataset.stimulus.stimTime(fnum, 1:8) = dataset.stimulus.stimTime(fnum, 1:8)+ (dataset.stimulus.stimTime(fnum, 2)); %assume (startDelay=Period) for stim timer
    end
    
    %save data
    dataset.stage = 1;
    dataset.filename = [drsave filesep fnsave];
    
    save(dataset.filename, 'dataset', '-v7.3') 
end

if dataset.stage<2 || opts.forceStage(2)

    
    disp('Starting Stage 2: Alignment')
    alignOpts.window = 30;  %maximum movement;
    alignOpts.nRefs = 3; %number of reference values to produce; we will use the most common one
    alignOpts.nFramesRef = 300; %create a reference from first nFramesRef frames
    alignOpts.doplot = false;
    alignOpts.prior.strength = 0.3;
    alignOpts.prior.width = 30;
    alignOpts.prior.sharpness = 50;
    alignOpts.chunkSize = 30;
    %align
    disp('aligning...')
    if all(opts.activityChan==opts.motionChan)
        [alignedA, ~,~] = align2D_notemplate(reshape(dataset.IM(:,:,:,opts.motionChan,:), size(dataset.IM,1), size(dataset.IM, 2), []), alignOpts); %ALIGN
    else %align other channels
        [~, shifts, ~] = align2D_notemplate(reshape(dataset.IM(:,:,:,opts.motionChan,:), size(dataset.IM,1), size(dataset.IM, 2), []), alignOpts); %ALIGN
        alignedA = zeros(size(dataset.IM,1), size(dataset.IM,2), size(shifts,2),size(dataset.IM,4), 'single');
        for ch = 1:length(opts.activityChan)
            imageSet= reshape(dataset.IM(:,:,:,opts.activityChan(ch),:), size(dataset.IM,1), size(dataset.IM, 2), []);
            imageSet(isnan(imageSet)) = nanmean(imageSet(randi(numel(imageSet),1, min(numel(imageSet), 1e6))));
            for frame = 1:size(imageSet,3)
                alignedA(:,:,frame,ch) = imtranslate(imageSet(:,:,frame), shifts(:,frame)', 'FillValues', prctile(reshape(imageSet(:,:,frame),1,[]), 5));
            end
            clear imageSet
        end
    end
    dataset = rmfield(dataset, 'IM');
    
    %correct slow noise
    disp('correcting slow noise...')
    
    for ch = 1:size(alignedA,4)
        smoothA = mean(alignedA(:,:,1:min(300,end),ch),3);
        threshA = prctile(smoothA(:), 50)+2;
        dimRef  = imerode(imdilate(smoothA<threshA, ones(3)), ones(7));
        for f = 1:size(alignedA,3)  %for each frame
            if mod(f,300)==151 && f<(size(alignedA,3)-150)
                smoothA = mean(alignedA(:,:,f-150:min(f+150,end), ch),3);
                threshA = prctile(smoothA(:), 50)+2;
                dimRef  = imerode(imdilate(smoothA<threshA, ones(3)), ones(7));
            end
            
            %correct row noise from slow digitizer fluctuations
            for row = 1:size(smoothA,1)
                select = dimRef(row,:);
                if sum(select)>30
                    alignedA(row,:,f,ch) = alignedA(row,:,f,ch) - (mean(alignedA(row,select,f,ch) - smoothA(row,select)));
                else
                    disp('too few pixels for correction')
                end
            end
        end
    end
    
    %register by strips
    dostrips = true;
    if dostrips
        inds = round(linspace(1,0.99*size(alignedA,3),256));
        ref = trimmean(alignedA(:,:,:,1),60,3);
        noiselevel = prctile(ref(:), 50)+5;
        tmp = registerByStrips(alignedA(:,:,inds,1),ref,noiselevel);
        ref = trimmean(tmp,60,3);
        alignedA = registerByStrips(alignedA,ref,noiselevel);
    end
%     dodemons = true;
%     ref = trimmean(alignedA(:,:,:,1),60,3);
%     noiselevel = prctile(ref(:), 50)+5;
%     if dodemons
%         for f =1:size(alignedA,3)
%             disp(['Nonrigid Align Frame:' int2str(f) ' of ' int2str(size(alignedA,3))])
%             [D, ~] = imregdemons(max(0, alignedA(:,:,f,1)-noiselevel), ref, [8 8 4], 'AccumulatedFieldSmoothing',3, 'PyramidLevels', 3, 'DisplayWaitBar', false);
%             for ch = 1:size(alignedA,4)
%                 alignedA(:,:,f,ch) = imwarp(alignedA(:,:,f,ch), D);
%             end
%         end
%     end
    
    %metric1 = ones(1,size(smoothA,3)); metric2 = ones(1,size(smoothA,3)); 
    metric3 = ones(1,size(smoothA,3));
    dataset.ref = ref;
    refHI = dataset.ref(:)>(noiselevel*1.5);
    %ptile = 100*sum(refHI(:))./numel(refHI);
    for f = 1:size(alignedA,3)
        maskF = imgaussfilt(alignedA(:,:,f,1), 0.6);
        %metric1(f) = -corr(maskF(:), dataset.ref(:));
        %metric2(f) = -corr(maskF(:)>prctile(maskF(:), ptile), refHI);
        metric3(f) = -corr(maskF(:)>(noiselevel*1.5), refHI);
    end
    motionMetric = metric3;
    
    dataset.motionMetric = motionMetric;
    dataset.aligned = reshape(alignedA, size(alignedA,1),size(alignedA,2), [], length(dataset.fns), size(alignedA,4));
    dataset.stage = 2;
    disp(['Saving dataset to: ' fnsave]);
    save([drsave filesep fnsave], 'dataset', '-v7.3') 
    disp('done save')
end

%censor motion and zero out baseline
if opts.doCensor
    M = imtophat(dataset.motionMetric, ones(1,100));
    censor = M-mean(M);
    thresh =  4*std(censor(censor<prctile(censor,90)));
    figure('Name', 'Motion'), plot(censor); hold on, plot([1 length(censor)],thresh*[1 1], 'r'); xlabel('frames'); ylabel('motion metric')
    censor = censor>thresh;
    disp([int2str(sum(censor)) ' of ' int2str(length(censor)) ' frames were censored due to motion']);
    drawnow;
    [r,c] = find(reshape(censor, size(dataset.aligned,3), size(dataset.aligned,4)));
    for ii = 1:length(r)
        dataset.aligned(:,:,r(ii),c(ii),:) = nan; %censor
    end
end
dataset.aligned = permute(dataset.aligned, [2 1 3 4 5]);

%accumulate responses to each stimulus
    onsets = nan(1,size(dataset.stimulus.stimTime,2));
    for i = 1:size(dataset.stimulus.stimTime,2)
        [~, onsets(i)] = min(abs(median(dataset.frameTimes,1)-median(dataset.stimulus.stimTime(:,i))));
    end
    onsets = 18:17:150; %TMP
    
    responseLength = min(diff(onsets));
    dataset.preFrames = opts.preFrames;
    preFrames = dataset.preFrames;
    responses = nan(size(dataset.aligned,1), size(dataset.aligned,2), responseLength,size(dataset.aligned,4), 8,size(dataset.aligned,5));
    for mov=1:size(dataset.aligned,4)
        for onset = 1:8
            responses(:,:,:,mov, dataset.stimulus.stim(mov,onset),:) = dataset.aligned(:,:,onsets(onset)+(1:responseLength)-preFrames,mov,:);
        end
    end
    
    %average image
    nChan = size(dataset.aligned,5);
    avgIMG = squeeze(trimmean(reshape(dataset.aligned,size(dataset.aligned,1),size(dataset.aligned,2),[],nChan),60,3));
    if opts.threshDense
         baseline1= prctile(reshape(avgIMG(:,:,1),1,[]),1);
    else
        baseline1= prctile(reshape(avgIMG(:,:,1),1,[]), 20);
    end
    avgIMG(:,:,1) = avgIMG(:,:,1)-baseline1;
    if nChan==2
        baseline2= median(reshape(avgIMG(:,:,2),1,[]));
        avgIMG(:,:,2) = avgIMG(:,:,2)-baseline2;
    end
    v =std(avgIMG(avgIMG(:,:,1)<prctile(avgIMG(:,:,1), 90)));
    brightPixels = avgIMG(:,:,1)>3*v;
    
    figname = dataset.filename;
    clear dataset;
    %linear unmixing
    if nChan==2
        responses = responses - reshape([baseline1 baseline2], [1 1 1 1 1 2]);
        
        %average across movies
        R2 = reshape(nanmean(responses,4), size(responses,1)*size(responses,2), [], 2);
        C1 = reshape(R2(brightPixels(:),:,1),[],1); 
        C2 = reshape(R2(brightPixels(:),:,2),[],1);
        
%         f = figure('Name', 'CLOSE WINDOW if using yGluSnFR/JRGECO; otherwise draw lines corresponding to regions of minimum and maximum slope for linear unmixing;');
%         scatter(C1,C2);
%         hold on, 
%         h1 = imline;
%         h2 = imline;
%         input('Hit Enter when ready to proceed>>')
%         try
%             pts1 = diff(h1.getPosition,[],1);
%             pts2 = diff(h2.getPosition,[],1);
%             if abs(pts2(2)./pts2(1))<abs(pts1(2)./pts1(1))
%                 keyboard
%             end
%             if prod(pts2)<0
%                 pts2 = [0 1];
%             end
%             if prod(pts1)<0
%                 pts1 = [1 0];
%             end
%             MM = [pts1./sum(pts1); pts2./sum(pts2)]; %mixing matrix
%         catch
           % MM = [0.9166 0.0834 ; 0 1];
            MM = [0.9310    0.0690 ; 0.0578    0.9422]; %mixing matrix for RGECO/yGluSnFR
%             keyboard
%         end
        %do unmixing
        avgUnmixed = reshape(reshape(avgIMG,[],2)/MM, size(avgIMG));
        responses = reshape(reshape(responses,[],2)/MM, size(responses));
        
        thresh1 = prctile(reshape(avgUnmixed(:,:,1), 1,[]), 99.99);
        thresh2 = prctile(reshape(avgUnmixed(:,:,2),1,[]), 99.88);
        figure, imshow(cat(3, avgUnmixed(:,:,2)./thresh2, avgUnmixed(:,:,1)./thresh1, avgUnmixed(:,:,1)./thresh1))
    end

    %show average responses to each stimulus
    prePeriod = 1:5;
    
    stimResp = nan(size(responses,1),size(responses,2),size(responses,3),8, size(responses,6));
    stimRespNotAveraged = nan(size(responses));
    stimRespSmooth = stimResp;
    for stim = 1:8
        stimRespNotAveraged(:,:,:,:,stim,:) = responses(:,:,:,:,stim,:) - repmat(nanmean(responses(:,:,prePeriod,:,stim,:),3), 1,1,size(responses,3));
        stimResp(:,:,:,stim,:) = nanmean(stimRespNotAveraged(:,:,:,:,stim,:),4);
    end
    
    %Subtract any general bleed-through/contamination of stimuli and plot
    P = reshape(stimResp, [size(stimResp,1)*size(stimResp,2) size(stimResp,3)*size(stimResp,4) size(stimResp,5)]);
    for ch = size(avgIMG,3):-1:1
        bleed(:,ch) =  median(P(avgIMG(:,:,ch)<2,:,ch),1);
    end
    stimResp = stimResp - reshape(bleed, 1,1,  size(stimResp,3), size(stimResp,4), size(stimResp,5));
    stimRespSmooth = imgaussfilt(stimResp,0.5);

    stimWindow = 6:13; %for new datasets
    disp(['Tuning is being calculated by averaging frames :' int2str(stimWindow)])
    
    for ch = size(stimResp,5):-1:1
        %HSV data
        %OVERALL AVERAGE
        rad = linspace(0,2*pi,8/2+1);
        rad = rad([1:4 1:4]);
        Sdata =  squeeze(mean(stimRespSmooth(:,:,stimWindow,:,ch),3));
        w = reshape(Sdata, [], size(Sdata,3));
        [H,S,V] = circular_mean(rad,w);

        if ~opts.threshDense
            disp('Intensity thresholding for dendritic imaging, not somata')
            %thresholding for dendrites
            E = std(V(V<prctile(V,95)));
            Vthresh = prctile(V(V>6*E),99.9);
        else
            disp('Intensity thresholding for somata, not dendritic imaging')
            %thresholding for dense imaging
            Vthresh = prctile(V,98);
        end
        
        V = V./Vthresh; V(V>1) = 1; V(V<0) = 0;
        
        Sthresh = max(0.8, prctile(S(V>0.2), 99));
        S = min(Sthresh, S)./Sthresh;
        
        respRGBavg{ch} =  reshape(hsv2rgb([H(:) S(:) V(:)]), [size(stimRespSmooth,1), size(stimRespSmooth,2), 3]);
        
        gamma = 0;
        for c = 1:3
            tmp = respRGBavg{ch}(:,:,c);
            factor = 1/mean(tmp(brightPixels)).^gamma;
            respRGBavg{ch}(:,:,c) = respRGBavg{ch}(:,:,c)*factor;
        end
        respRGBavg{ch} = respRGBavg{ch}./max(respRGBavg{ch}(:));
        
        %Response in Photons
        figure('name', ['Channel ' int2str(ch) 'Intensity Threshold: ' num2str(Vthresh)]), imshow(respRGBavg{ch})

        %Response in Sqrt(Photons)
        figure('name', ['Channel ' int2str(ch) 'Intensity Threshold: ' num2str(Vthresh)]), imshow(sqrt(respRGBavg{ch}))
        
        %Response in dFF
        SdataDFF = squeeze(mean(stimRespSmooth(:,:,stimWindow,:,ch),3))./(max(0,imgaussfilt(avgIMG(:,:,ch),1))+1);
        w = reshape(SdataDFF, [], size(SdataDFF,3));
        [H,S,V] = circular_mean(rad,w);
        
        DFFthresh = 5;
        V = V./DFFthresh; V(V>1) = 1; V(V<0) = 0;
        Sthresh = max(0.8, prctile(S(V>0.2), 99));
        S = min(Sthresh, S)./Sthresh;
        respRGBavgDFF{ch} =  reshape(hsv2rgb([H(:) S(:) V(:)]), [size(stimRespSmooth,1), size(stimRespSmooth,2), 3]);
        figure('name', ['DFF; Channel ' int2str(ch)]), imshow(respRGBavgDFF{ch})
        
    end
    clear stimRespSmooth;
    colors = hsv(8);
    resp = reshape(stimResp, size(stimResp,1)*size(stimResp,2), size(stimResp,3), size(stimResp,4), size(stimResp,5));
    respNotAveraged = reshape(stimRespNotAveraged, [size(stimResp,1)*size(stimResp,2), size(stimRespNotAveraged,3), size(stimRespNotAveraged,4),size(stimRespNotAveraged,5), size(stimRespNotAveraged,6)]);
    abort = false;

    hFig = figure('name', [figname '; Select a region of interest']);
    set(hFig, 'CloseRequestFcn', @exitKP);
    hIm = imshow(respRGBavg{1});
    hAx = get(hIm, 'parent'); hold(hAx, 'on')
    nCh = size(resp,4);
    ROIs = [];
    [fnS drS] = uiputfile('Save ROIs');
    while ~abort
        figure(hFig); axes(hAx);
        bw = roipoly;
        ROIs(end+1).bw = bw;
        [outline] = bwboundaries(bw);
        if ~ishandle(hFig) || isempty(bw)
            abort = true;
            break;
        end 
        plot(hAx, outline{1}(:,2), outline{1}(:,1), ':w', 'linewidth', 2);
        text(max(outline{1}(:,2)), max(outline{1}(:,1)), int2str(length(ROIs)), 'color', 'w');
        %figure('name', ['Raster responses' int2str(ch)], 'color', 'w'),
        for ch = 1:size(resp,4)
            %subplot(2,nCh,2*ch-1)
            hF1 = figure('name', ['ROI ' int2str(length(ROIs))], 'pos', [215   394   379   420]);
            f0 = max(1,avgIMG(:,:,ch));
            f0 = nanmean(f0(bw));
            ROIs(end).f0 = f0;
            Rmean = squeeze(nanmean(nanmean(resp(bw,stimWindow,:,ch),1),2));
            Rstd = squeeze(nanstd(nanmean(nanmean(respNotAveraged(bw,stimWindow,:,:,ch),1),2),0,3))./sqrt(size(respNotAveraged,3));
            errorbar(Rmean./f0, Rstd./f0, 'color', 'k', 'linewidth', 2, 'linestyle', ':');
            for i = 1:8
                hold on
                scatter(i, Rmean(i)./f0, 'sizedata', 120, 'markerfacecolor', colors(i,:), 'markeredgecolor', 'k', 'linewidth', 2)
            end
            set(gca, 'linewidth', 2, 'tickdir', 'out', 'box', 'off', 'xlim', [0.5 8.5]); %, 'ylim', [-0.1 0.4])
            xlabel('Stimulus #')
            ylabel('dFF')
            ROIs(end).tuning = Rmean./f0;
            ROIs(end).tuningErr = Rstd./f0;
            saveas(hF1, [drS filesep fnS 'ROI' int2str(length(ROIs)) 'tuning.eps'], 'epsc')
            
            %subplot(2,nCh,2*ch)
            hF2 = figure('name', ['ROI ' int2str(length(ROIs))], 'pos', [215   394   379   420]);
            Rmean = squeeze(nanmean(resp(bw(:), :,:, ch),1));
            Rstd = squeeze(nanstd(nanmean(respNotAveraged(bw,:,:,:,ch),1),0,3))./sqrt(size(respNotAveraged,3));
            for i = 1:8
                hold on,
                plot(Rmean(:,i)./f0, 'color', colors(i,:), 'linewidth', 2);
                patch([1:size(Rstd,1) fliplr(1:size(Rstd,1))]', [Rmean(:,i)+Rstd(:,i) ; flipud(Rmean(:,i)-Rstd(:,i))]./f0, colors(i,:),'edgecolor', 'none', 'FaceAlpha', 0.3);
            end
            xlabel('Time (frames)'); ylabel('dFF');
            set(gca, 'linewidth', 2, 'tickdir', 'out'); %, 'ylim', [-0.2 0.6])
            ROIs(end).trace = Rmean./f0;
            ROIs(end).traceErr = Rstd./f0;
            saveas(hF2, [drS filesep fnS 'ROI' int2str(length(ROIs)) 'trace.eps'], 'epsc')
        end
        abort = ~ishandle(hFig);
    end
    save([drS fnS], 'ROIs');
end

function [H,S,V] = circular_mean(rad,w)
A = sum(exp(1i*rad).*w,2);
H = 1/2 + angle(A)/(2*pi);

S = abs(A)./sum(abs(w),2);
V = sqrt(sum(w.^2,2));
end

function yy = findPhase(IMset)
edgecut = 15;
blocksize = 5;
shifts = -2:0.5:2;
sorted1 = nth_element(IMset(:), ceil(numel(IMset)*0.5));
sorted2 = nth_element(IMset(:), ceil(numel(IMset)*0.01));
noiselevel = sorted1(ceil(numel(IMset)*0.5)) + (sorted1(ceil(numel(IMset)*0.05)) - sorted2(ceil(numel(IMset)*0.01)));
%noiseamp = nanmedian(IMset(:))-prctile(IMset(:), 1) + 40; %3*sqrt(estimatenoise(reshape(IMset(:,:,1), 1,[]))); %estimate of digitizer noise; this should be less than the signal of a single photon

H2 = floor((size(IMset,1)-1)/2);
cols = edgecut+max(shifts)+1:blocksize:size(IMset,2)-edgecut + min(shifts);
rowshift = nan(length(cols), size(IMset,3));
GOF = nan(size(rowshift));

for frameix = 1:size(IMset,3)
    IM1 = medfilt2(IMset(1:2:2*H2,:,frameix),[3 3]);
    IM1 = max(0, IM1-noiselevel);
    IM2 = medfilt2(IMset(2:2:2*H2,:,frameix),[3 3]);
    IM2 = max(0, min(IM2, max(IM2(:))-noiselevel));
    IM3 = [IM1(2:end,:); zeros(1,size(IM1,2))];
    
    CC = normxcorr2_general(IM1,IM2, 0.9*numel(IM1));
    [~,maxix] = max(CC(:)); [~,j] = ind2sub(size(CC), maxix);
    meanShift = j-size(IM1,2);
    
    %IM1int = griddedInterpolant(IM1);
    IM2int = griddedInterpolant(IM2);
    for col_ix = 1:length(cols)
        col = cols(col_ix);
        E1 = nan(1, length(shifts));
        E3 = E1;
        for shiftix = 1:length(shifts)
            IM2col = IM2int({1:size(IM2,1), col+meanShift-shifts(shiftix) + (-blocksize:blocksize)});
            E1(shiftix) = sum(sum(abs(IM1(:,col + (-blocksize:blocksize))-IM2col)));
            E3(shiftix) = sum(sum(abs(IM3(:,col+ (-blocksize:blocksize))-IM2col)));
            %better distance metric?
        end
        if sum(~isnan(E1))>3 && sum(~isnan(E3))>3
            [minE1, minIX1] = min(E1);
            [minE3, minIX3] = min(E3);
            rowshift(col_ix, frameix) = -meanShift + (shifts(minIX1) + shifts(minIX3))/2;
            GOF(col_ix,frameix) = (mean(E1)-minE1) + (mean(E3)-minE3);
        end
    end
end

%WEIGHT EACH ROWSHIFT MEASUREMENT BY THE QUALITY OF FIT
weight = nansum(GOF,2);
rowshift = nansum((rowshift+meanShift).*GOF,2)./(weight + nanmax(weight)/50) -meanShift;
meanShift = -(nansum(rowshift.*weight)./nansum(weight));
rowshift(isnan(rowshift)) = -meanShift;
rowshift = medfilt2(rowshift, [3 1]); %filter out brief inconsistent spikes
cs = csaps([1 cols size(IMset,2)],[-meanShift rowshift' -meanShift],1e-8,[], [nanmax(weight)/10; weight ;nanmax(weight)/10]);
yy = fnval(cs, 1:size(IMset,2));
% figure('name', 'Phase Correction'), scatter(cols, rowshift')
% hold on, plot(yy)
end

function [IMcorrected, yy] = fixPhase(IMset, yy)
%apply correction
IMcorrected = IMset;
grid = 1:size(IMset,2);
for ix = 1:size(IMset,3)
    IMcorrected(2:2:end,:,ix) = interp1(grid', IMset(2:2:end,:,ix)', grid-yy)';  %IM2int({IM2int.GridVectors{1}, grid-yy});
end
end

function imX = registerByStrips(imX,ref, noiseamp)
smoothing = 8.3;
stripheight = 16;
ref = ref-min(ref(:));
%refFilt = ref - imgaussfilt(ref, stripheight/2);
edgecut = stripheight;
medX = max(0, imX(:,:,:,1)-noiseamp);
rowCs = stripheight+1:stripheight/2:size(imX,1)-stripheight;
outsize = [2*stripheight+1 size(ref,2)]+[stripheight+1 size(medX,2)-(2*edgecut)]-1;
for rowIX = length(rowCs):-1:1
    a = ref(rowCs(rowIX)+(-stripheight:stripheight),:);
    fftArot(:,:,rowIX) = fft2(rot90(a,2),outsize(1),outsize(2));
end
lsA = nan([outsize length(rowCs)]); lsA2 = lsA;
for T = 1:size(imX,3)
    T
    warpX = nan(1,size(imX,1));
    warpY = nan(1,size(imX,1));
    GOF = warpX;
    for rowIX = 1:length(rowCs)
        rowC = rowCs(rowIX);
        b = medX(rowC+(-stripheight/2:stripheight/2),edgecut+1:end-edgecut,T);
        if T==1
            [C , lsA(:,:,rowIX), lsA2(:,:,rowIX)] = normxcorr2_general_FFT(b, ref(rowC+(-stripheight:stripheight),:), fftArot(:,:,rowIX), [],[],numel(b));
            C = rot90(C,2);
        else
            C = rot90(normxcorr2_general_FFT(b, ref(rowC+(-stripheight:stripheight),:), fftArot(:,:,rowIX), lsA(:,:,rowIX), lsA2(:,:,rowIX),numel(b)),2);
        end
        %C = freqxcorr(fftArot(:,:,rowIX),b,outsize);
        %C2 = normxcorr2_general(b, ref(rowC+(-stripheight:stripheight),:), 100);
        %C = xcorr2(ref(rowC+(-stripheight:stripheight),:), medX(rowC+(-stripheight/2:stripheight/2),edgecut+1:end-edgecut));
        [~, op] = max(C(:)); %minC = min(min(C(ceil((size(C,1)-stripheight)/2):floor((size(C,1)+stripheight)/2), ceil((size(C,2)-stripheight)/2):floor((size(C,2)+stripheight)/2))));
        [opX,opY] = ind2sub(size(C), op);
        warpX(rowC) = -(opX-ceil(size(C,1)/2));
        warpY(rowC) = -(opY-ceil(size(C,2)/2));
        GOF(rowC) = sum(b(:)); %maxC-minC;
    end
    GOF = GOF-0.9*nanmin(GOF);
    discard = isnan(warpX) | isnan(warpX) | abs(warpX)>=(stripheight/2-1) | abs(warpY)>=(stripheight/2-1);
    warpX(discard) = 0;
    warpY(discard) = 0;
    GOF(discard) = 0;
    weight = GOF;
    weight([1 end]) = nanmax(weight)/100;
    
    csX = csaps(1:length(warpX),warpX',10^(-smoothing),[], weight);
    xx = fnval(csX, 1:length(warpX));
    csY = csaps(1:length(warpY),warpY',10^(-smoothing),[], weight);
    yy = fnval(csY, 1:length(warpY));
    
    D = cat(3, -repmat(yy', 1, size(imX,2)), -repmat(xx', 1, size(imX,2)));
    for ch = 1:size(imX,4)
        imX(:,:,T,ch) = imwarp(imX(:,:,T,ch),D);
    end
end
end

% function xcorr_ab = freqxcorr(Fa,b,outsize)
% % calculate correlation in frequency domain
% %Fa = fft2(rot90(a,2),outsize(1),outsize(2));
% Fb = fft2(b,outsize(1),outsize(2));
% xcorr_ab = ifft2(Fa .* Fb,'symmetric');
% end

function  SI = parseMetaData(Mstring)
SI = [];
Mstring = strsplit(Mstring, '\n');
try
    for i = 1:length(Mstring)
        eval([Mstring{i} ';']);
    end
catch
    i = i-1;
end
SI.rois = loadjson(strjoin(Mstring(i+1:end), '\n'));
end

    function exitKP(src, evnt)
        if strcmp(questdlg('Exit SI Tuning?', 'SITuning', 'Yes', 'No', 'No'), 'Yes')
            delete(src);
        end
    end