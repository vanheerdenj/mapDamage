
getTheta <- function(tmu){
    #Using the Juke-Cantor model
    return(matrix(rep(1/4-exp(-tmu)/4,16),nrow=4,ncol=4)+diag(rep(exp(-tmu),4)))
}

metroDesc <- function(lpr,lol){
    stopifnot(!is.na(lpr))
    stopifnot(!is.na(lol))
    if (log(runif(1))<lpr-lol){
        return(1)
    }else {
        return(0)
    }
}

genOverHang <- function(la){
    r <- runif(1)
    i <- -1
    p <- 0
    while (p< r){
        if (i==-1){
            term <- 1
        }else {
            term  <- 0
        }
        p <-p+ (la*((1-la)**(i+1))+term)/2
        i <- i+1
    }
    return(i)
}

sampleHJ <- function(x,size,prob){
    if (length(prob)==1){
        return(rep(x,size))
    }else {
        return(sample(x,size=size,prob=prob,replace=TRUE))
    }
}


estLinNuVector <- function(nuVec,cp){
    #Since the nick frequency is supposed to 
    #be uniform on the double stranded interval 
    #we fit the site specific probabilities with 
    #a line.
    model <- lm(nuVec[1:(cp$m/2)]~c(1:(cp$m/2)))
    tempNuVec <- predict(model)
    tempNuVec[tempNuVec>1] <-1 
    tempNuVec[tempNuVec<0] <-0
    return(c(tempNuVec,rev(1-tempNuVec)))
}

seqProbVecLambda <- function(lambda,lambda_disp,m,fo_only){
    psum <- matrix(ncol=1,nrow=m)
    pvals <- dnbinom(c(1:m)-1,prob=lambda,size=lambda_disp)
    for (i in 1:m){
        psum[i,1] <- (1-sum(pvals[1:i]))/2
    }
    if (fo_only){
        return(c(psum))
    }else {
        psum <- c(psum[1:(m/2),1],rev(psum[1:(m/2),1]))
        return(c(psum))
    }
}

seqProbVecNuWithLengths<- cxxfunction( signature(
                                      I_la="numeric",
                                      I_la_disp="numeric",
                                      I_nu="numeric",
                                      I_m="numeric",
                                      I_lengths="numeric",
                                      I_mLe="numeric",
                                      I_fo="numeric",
                                      I_iter="numeric",
                                      I_ds_protocol="numeric"
                             ) ,includes='
                  #include <gsl/gsl_randist.h>
                  int genOverHang(double la,double la_disp)
                  {
                      double r = ((double) rand() / (RAND_MAX));
                      int i = -1;
                      double p = 0;
                      double term = -500; 
                      while (p<r){
                          if (i==-1){
                              term = 1;
                          }else {
                              term = 0;
                          }
                          p = p + (gsl_ran_negative_binomial_pdf(i+1,la,la_disp)+term)/2;
                          i++;
                      }
                      return(i);
                  }
                  ',body= '
              srand(time(0)); 
        Rcpp::NumericVector la(I_la);
        Rcpp::NumericVector la_disp(I_la_disp);
        Rcpp::NumericVector nu(I_nu);
        Rcpp::NumericVector m(I_m);
        Rcpp::NumericVector les(I_lengths);
        Rcpp::NumericVector mLe(I_mLe);
        Rcpp::NumericVector fo(I_fo);
        Rcpp::NumericVector iter(I_iter);
        Rcpp::NumericVector ds_protocol(I_ds_protocol);
//
        Rcpp::NumericVector output(mLe[0]);
        Rcpp::NumericVector reduced_output(m[0]);
        if (ds_protocol[0]==0){
            for (int j = 0; j < m[0];j++){
                reduced_output(j) = 1;
            }
            return(reduced_output);
        }else {
            for (int i = 0; i < iter[0];i++ ){
//
                double left_o_hang = genOverHang(la[0],la_disp[0]);
                double right_o_hang = genOverHang(la[0],la_disp[0]);
                double o_hang  = left_o_hang+right_o_hang;
//              
                if (o_hang>=les(i)){
                    //Single stranded sequence
                    for (int j = 0; j <les(i);j++){
                        output(j) = output(j)+1;
                    }
                } else {
                    Rcpp::NumericVector r = runif(1);
                    if (r[0]< (1-nu[0])/((les[i]-o_hang-1)*nu[0]+(1-nu[0]))){
                        for (int j = 0; j <(les[i]-right_o_hang);j++){
                            output(j) = output(j)+1;
                        }
                        //The right overhang is always G>A for the double stranded but 
                        //Here we will make the assumption that the pattern is symmetric 
                        //for practical reasons We can\'t  do that ....
                    }else {
                        Rcpp::NumericVector sa = floor(runif(1,0,les[i]-o_hang))+left_o_hang;
                        for (int j = 0; j <=sa[0];j++){
                            output(j) = output(j)+1;
                        }
                    }
                }
            }
            if (fo(0)){
                //Only considering the forward part
                for (int j = 0; j < m[0];j++){
                    reduced_output(j) = output(j)/iter(0);
                }
            }else {
                for (int j = 0; j < m[0]/2;j++){
                    reduced_output(j) = output(j)/iter(0);
                    reduced_output(m[0]-j-1) = 1-output(j)/iter(0);
                }
            }
            return(reduced_output);
        }
',plugin='RcppGSL' )




pDam <- function(th,ded,des,la,nu,lin){
    #The damage and mutation matrix multiplied together
    pct <- nu*(la*des+ded*(1-la))
    pga <- (1-nu)*(la*des+ded*(1-la))
    return(
           c(
             th[lin,1]*1+th[lin,3]*pga
             ,
             th[lin,2]*(1-pct)
             ,
             th[lin,3]*(1-pga)
             ,
             th[lin,2]*pct+th[lin,4]*1
             )
           )
}

logLikFunOneBaseSlow <- function(Gen,S,Theta,deltad,deltas,laVec,nuVec,m,lin){
    #This is the main workhorse of the program
    ll <- 0
    for (i in 1:length(laVec)){
        #Get the damage probabilities
        pd <- pDam(Theta,deltad,deltas,laVec[i],nuVec[i],lin)
        ll <- ll + dmultinom(S[i,],Gen[i],pd,log=TRUE)
    }
    return(ll)
}

logLikFunOneBaseFast <- cxxfunction(signature(
                                      I_Gen="numeric",
                                      I_S="numeric",
                                      I_Theta="numeric",
                                      I_deltad="numeric",
                                      I_deltas="numeric",
                                      I_laVec="numeric",
                                      I_nuVec="numeric",
                                      I_m="numeric",
                                      I_lin="numeric"
                                      ), body = '
Rcpp::NumericMatrix S(I_S);
Rcpp::NumericMatrix th(I_Theta);

Rcpp::NumericVector Gen(I_Gen);

Rcpp::NumericVector Vded(I_deltad);
double ded = Vded[0];

Rcpp::NumericVector Vdes(I_deltas);
double des = Vdes[0];

Rcpp::NumericVector laVec(I_laVec);

Rcpp::NumericVector nuVec(I_nuVec);

Rcpp::NumericVector Vm(I_m);
int m = Vm[0];

Rcpp::NumericVector Vlin(I_lin);
int lin = Vlin[0];

Rcpp::NumericVector pDam(4);

Rcpp::NumericVector ret(1);
ret[0] = 0;

for (int i = 0; i<laVec.size();i++){
    double la = laVec[i];
    double nu = nuVec[i];
    double pct = nu*(la*des+ded*(1-la));
    double pga = (1-nu)*(la*des+ded*(1-la));
    pDam[0] = th(lin-1,0)*1+th(lin-1,2)*pga;
    pDam[1] = th(lin-1,1)*(1-pct);
    pDam[2] = th(lin-1,2)*(1-pga);
    pDam[3] = th(lin-1,1)*pct+th(lin-1,3)*1;
    double p1 = gsl_sf_lnfact(Gen(i))
               -gsl_sf_lnfact(S(i,0))
               -gsl_sf_lnfact(S(i,1))
               -gsl_sf_lnfact(S(i,2))
               -gsl_sf_lnfact(S(i,3));
    double p2 = S(i,0)*log(pDam[0])
               +S(i,1)*log(pDam[1])
               +S(i,2)*log(pDam[2])
               +S(i,3)*log(pDam[3]);
    ret[0] = ret[0] + p1 + p2;
}
return(ret);
', plugin="RcppGSL",include="#include <gsl/gsl_sf_gamma.h>")

logLikAll <- function(dat,Theta,deltad,deltas,laVec,nuVec,m,meanLength,forward_only){

    if (deltad<0 || deltad>1 || deltas<0 || deltas>1  ){
        return(-Inf)
    }
    #A,C,G and T

    deb <- 0
    
    Asub <- dat[,"A.C"]+dat[,"A.G"]+dat[,"A.T"]    
    ALL <- logLikFunOneBaseFast(dat[,"A"],cbind(dat[,"A"]-Asub,dat[,"A.C"],dat[,"A.G"],dat[,"A.T"]),Theta,deltad,deltas,laVec,nuVec,m,1)
    if (deb){
        ALLSlow <- logLikFunOneBaseSlow(dat[,"A"],cbind(dat[,"A"]-Asub,dat[,"A.C"],dat[,"A.G"],dat[,"A.T"]),Theta,deltad,deltas,laVec,nuVec,m,1)
        stopifnot(all.equal(ALL,ALLSlow))
    }

    Csub <- dat[,"C.A"]+dat[,"C.G"]+dat[,"C.T"]
    CLL <- logLikFunOneBaseFast(dat[,"C"],cbind(dat[,"C.A"],dat[,"C"]-Csub,dat[,"C.G"],dat[,"C.T"]),Theta,deltad,deltas,laVec,nuVec,m,2)
    if (deb){
        CLLSlow <- logLikFunOneBaseSlow(dat[,"C"],cbind(dat[,"C.A"],dat[,"C"]-Csub,dat[,"C.G"],dat[,"C.T"]),Theta,deltad,deltas,laVec,nuVec,m,2)
        stopifnot(all.equal(CLL,CLLSlow))
    }
    

    Gsub <- dat[,"G.A"]+dat[,"G.C"]+dat[,"G.T"]
    GLL <- logLikFunOneBaseFast(dat[,"G"],cbind(dat[,"G.A"],dat[,"G.C"],dat[,"G"]-Gsub,dat[,"G.T"]),Theta,deltad,deltas,laVec,nuVec,m,3)
    if (deb){
        GLLSlow <- logLikFunOneBaseSlow(dat[,"G"],cbind(dat[,"G.A"],dat[,"G.C"],dat[,"G"]-Gsub,dat[,"G.T"]),Theta,deltad,deltas,laVec,nuVec,m,3)
        stopifnot(all.equal(CLL,CLLSlow))
    }
    
    Tsub <- dat[,"T.A"]+dat[,"T.C"]+dat[,"T.G"]
    TLL <- logLikFunOneBaseFast(dat[,"T"],cbind(dat[,"T.A"],dat[,"T.C"],dat[,"T.G"],dat[,"T"]-Tsub),Theta,deltad,deltas,laVec,nuVec,m,4)
    if (deb){
        TLLSlow <- logLikFunOneBaseSlow(dat[,"T"],cbind(dat[,"T.A"],dat[,"T.C"],dat[,"T.G"],dat[,"T"]-Tsub),Theta,deltad,deltas,laVec,nuVec,m,4)
        stopifnot(all.equal(TLL,TLLSlow))
    }
    return(ALL+CLL+GLL+TLL)
}


getParams <- function(cp){
    return(c(cp$Theta,cp$DeltaD,cp$DeltaS,cp$Lambda,cp$LambdaRight,cp$LambdaDisp,cp$Nu))
}

plotEverything <- function(mcmcOut,hi=0,pl){
    if (sum(c(cu_pa$same_overhangs==FALSE,
                    cu_pa$fix_disp==FALSE,
                    cu_pa$nuSamples!=0))>1){
        #Check if I need to add a extra row
        a_extra_row <- 1
    }else {
        a_extra_row <- 0
    }
    par(mfrow=c(3,2+a_extra_row))
    if(hi){
        hist(mcmcOut$out[,"Theta"],main="Theta",xlab="",freq=FALSE)
        hist(mcmcOut$out[,"DeltaD"],main="DeltaD",xlab="",freq=FALSE)
        hist(mcmcOut$out[,"DeltaS"],main="DeltaS",xlab="",freq=FALSE)
        hist(mcmcOut$out[,"Lambda"],main="Lambda",xlab="",freq=FALSE)
        if (!mcmcOut$cu_pa$same_overhangs){
            hist(mcmcOut$out[,"LambdaRight"],main="LambdaRight",xlab="",freq=FALSE)
        }
        if (!mcmcOut$cu_pa$fix_disp){
            hist(mcmcOut$out[,"LambdaDisp"],main="LambdaDisp",xlab="",freq=FALSE)
        }
        if (mcmcOut$cu_pa$nuSamples!=0){
            hist(mcmcOut$out[,"Nu"],main="Nu",xlab="",freq=FALSE)
        }
        hist(mcmcOut$out[,"LogLik"],main="LogLik",xlab="",freq=FALSE)
    }else {
        plot(mcmcOut$out[,"Theta"],xlab="iteration",ylab="Theta")
        plot(mcmcOut$out[,"DeltaD"],xlab="iteration",ylab="DeltaD")
        plot(mcmcOut$out[,"DeltaS"],xlab="iteration",ylab="DeltaS")
        plot(mcmcOut$out[,"Lambda"],xlab="iteration",ylab="Lambda")
        if (!mcmcOut$cu_pa$same_overhangs){
            plot(mcmcOut$out[,"LambdaRight"],xlab="iteration",ylab="LambdaRight")
        }
        if (!mcmcOut$cu_pa$fix_disp){
            plot(mcmcOut$out[,"LambdaDisp"],xlab="iteration",ylab="LambdaDisp")
        }
        if (mcmcOut$cu_pa$nuSamples!=0){
            plot(mcmcOut$out[,"Nu"],xlab="iteration",ylab="Nu")
        }
        plot(mcmcOut$out[,"LogLik"],xlab="iteration",ylab="LogLik")
    }
    par(mfrow=c(1,1))
}

accRat <- function(da){
    return(length(unique(da))/length(da))
}

adjustPropVar <- function(mcmc,propVar){
    #Adjust the proposal variance to get something near .22
    for (i in colnames(mcmc$out)){
        if (i=="LogLik"){
            next
        } else if (i=="LambdaRight" & mcmc$cu_pa$same_overhangs){
            next
        } else if (i=="Nu" & mcmc$cu_pa$nuSamples==0){
            next
        } else if (i=="LambdaDisp" & mcmc$cu_pa$fix_disp){
            next
        }
        rat <- accRat(mcmc$out[,i])
        if (rat<0.1){
            propVar[[i]] <- propVar[[i]]/2
        } else if (rat>0.3) {
            propVar[[i]] <- propVar[[i]]*2
        }
    }
    return(propVar)
}

runGibbs <- function(cu_pa,iter){
    esti <- matrix(nrow=iter,ncol=8)
    colnames(esti) <- c("Theta","DeltaD","DeltaS","Lambda","LambdaRight","LambdaDisp","Nu","LogLik")
    for (i in 1:iter){
        cu_pa<-updateTheta(cu_pa)
        cu_pa<-updateDeltaD(cu_pa)
        cu_pa<-updateDeltaS(cu_pa)
        cu_pa<-updateLambda(cu_pa)
        if (!cu_pa$same_overhangs){
            #Not the same overhangs update lambda right
            cu_pa <- updateLambdaRight(cu_pa)
        }
        if (!cu_pa$fix_disp){
            #Allowing dispersion in the overhangs
            cu_pa<-updateLambdaDisp(cu_pa)
        }
        if (cu_pa$nuSamples!=0){
            #Update the nu parameter by via MC estimation
            cu_pa<-updateNu(cu_pa)
        }
        esti[i,c(1:7)] <- getParams(cu_pa) 
        esti[i,"LogLik"] <- logLikAll(cu_pa$dat,cu_pa$ThetaMat,cu_pa$DeltaD,cu_pa$DeltaS,cu_pa$laVec,cu_pa$nuVec,cu_pa$m,cu_pa$meanLength,cu_pa$forward_only)
        if (! (i %% 1000)){
            cat("MCMC-Iter\t",i,"\t",esti[i,"LogLik"],"\n")
        }
    }
    return(list(out=esti,cu_pa=cu_pa))
}

checkIfInsideConf <- function(out,ref_val=c(0,0,0,0,0)){
    ret <- rep(NA,5)
    for (i in 1:length(ref_val)){
        if (i==1){
            inT <- quantile(1/4-exp(-mcmcOut$out[,i])/4,c(0.025,.975))
        }else {
            inT <- quantile(mcmcOut$out[,i],c(0.025,.975))
        }
        if (inT[1]<ref_val[i] && ref_val[i]<inT[2]){
            ret[i] <- TRUE
        }else {
            ret[i] <- FALSE
        }
    }
    return(ret)
}

statsData <- function(out,para){
    te <- c(mean(out[,para]),quantile(out[,para],c(0.05,0.95)))
    names(te)[1] <-para 
    return(te)
}

simPredCheck <- function(da,output){
    bases <- da[,c("A","C","G","T")]
    #
    if (output$cu_pa$same_overhangs){
        laVec <- seqProbVecLambda(sample(output$out[,"Lambda"],1),sample(output$out[,"LambdaDisp"],1),output$cu_pa$m,output$cu_pa$forward_only)
    }else {
        laVecLeft <- seqProbVecLambda(sample(output$out[,"Lambda"],1),sample(output$out[,"LambdaDisp"],1),output$cu_pa$m,0)
        laVecRight <- seqProbVecLambda(sample(output$out[,"LambdaRight"],1),sample(output$out[,"LambdaDisp"],1),output$cu_pa$m,0)
        laVec <- c(laVecLeft[1:(output$cu_pa$m/2)],laVecRight[(output$cu_pa$m/2+1):output$cu_pa$m])
    }
    if (output$cu_pa$nuSamples !=0){
    nuVec <- seqProbVecNuWithLengths(sample(output$out[,"Lambda"],1),sample(output$out[,"LambdaDisp"],1),sample(output$out[,"Nu"],1),nrow(cu_pa$dat),
                                               sampleHJ(output$cu_pa$lengths$Length,size=output$cu_pa$laSamples,prob=output$cu_pa$lengths$Occurences),output$cu_pa$mLe,
                                           output$cu_pa$forward_only,output$cu_pa$nuSamples,output$cu_pa$ds_protocol) 
    nuVec <- c(nuVec,rev(1-nuVec))
    }else {
        nuVec <- output$cu_pa$nuVec
    }
    des <- sample(output$out[,"DeltaS"],1)
    ded <- sample(output$out[,"DeltaD"],1)
    ptrans <- 1/4-exp(-sample(output$out[,"Theta"],1))/4
    #
    coln <- c("A.C","A.G","A.T","C.A","C.G","C.T","G.A","G.C","G.T","T.A","T.C","T.G")
    subs <- matrix(NA,nrow=nrow(output$cu_pa$dat),ncol=4+length(coln))
    colnames(subs) <- c("A","C","G","T",coln)
    Theta <- matrix(ptrans,4,4)
    diag(Theta) <- 1-3*ptrans
    for (i in 1:nrow(output$cu_pa$dat)){
        pct <- nuVec[i]*(laVec[i]*des+ded*(1-laVec[i]))
        pga <- (1-nuVec[i])*(laVec[i]*des+ded*(1-laVec[i]))
        pDam <- matrix(c(
                         1,0,0,0,
                         0,1-pct,0,pct,
                         pga,0,1-pga,0,
                         0,0,0,1
                         ),nrow=4,byrow=TRUE)
        ThetapDam <- pDam %*% Theta
        subs[i,c("A.C","A.G","A.T")] <- t(rmultinom(1,output$cu_pa$dat[i,"A"],ThetapDam[1,]))[-1]/output$cu_pa$dat[i,"A"]
        subs[i,c("C.A","C.G","C.T")] <- t(rmultinom(1,output$cu_pa$dat[i,"C"],ThetapDam[2,]))[-2]/output$cu_pa$dat[i,"C"]
        subs[i,c("G.A","G.C","G.T")] <- t(rmultinom(1,output$cu_pa$dat[i,"G"],ThetapDam[3,]))[-3]/output$cu_pa$dat[i,"G"]
        subs[i,c("T.A","T.C","T.G")] <- t(rmultinom(1,output$cu_pa$dat[i,"T"],ThetapDam[4,]))[-4]/output$cu_pa$dat[i,"T"]
    }
    return(subs)
}

postPredCheck <- function(da,output,samples=1000){
    CTs <- matrix(NA,nrow=nrow(da),ncol=samples)
    GAs <- matrix(NA,nrow=nrow(da),ncol=samples)
    REs <- matrix(NA,nrow=nrow(da),ncol=samples)
    for (i in 1:samples){
        subs <- simPredCheck(da,output)
        CTs[,i] <- subs[,"C.T"]
        GAs[,i] <- subs[,"G.A"]
        REs[,i] <- apply(subs[,c("A.C","A.G","A.T","C.A","C.G","G.C","G.T","T.A","T.C","T.G")],1,mean)
    }
    subs <- simPredCheck(da,output)
    #plot(da[,"C.T"]/da[,"C"],col="blue",pch="+")
    CTsStats <- data.frame(x=c(1:nrow(da)),
                           mea=apply(CTs,1,mean),
                           med=apply(CTs,1,median),
                           loCI=apply(CTs,1,quantile,c(0.025)),
                           hiCI=apply(CTs,1,quantile,c(0.975)))
    GAsStats <- data.frame(x=c(1:nrow(da)),
                           mea=apply(GAs,1,mean),
                           med=apply(GAs,1,median),
                           loCI=apply(GAs,1,quantile,c(0.025)),
                           hiCI=apply(GAs,1,quantile,c(0.975)))
    REsStats <- data.frame(x=c(1:nrow(da)),
                           mea=apply(REs,1,mean),
                           med=apply(REs,1,median),
                           loCI=apply(REs,1,quantile,c(0.025)),
                           hiCI=apply(REs,1,quantile,c(0.975)))
    plot(ggplot()+
         geom_point(aes(x,mea,colour="C2T",aes_string="subs"),data=CTsStats)+
         geom_point(aes(x,mea,colour="G2A"),data=GAsStats)+
         geom_point(aes(x,mea,colour="Res"),data=REsStats)+
         geom_errorbar(aes(x=x,y=med,ymin=loCI,ymax=hiCI,color="C2T"),data=CTsStats)+
         geom_errorbar(aes(x=x,y=med,ymin=loCI,ymax=hiCI,color="G2A"),data=GAsStats)+
         geom_errorbar(aes(x=x,y=med,ymin=loCI,ymax=hiCI,color="Res"),data=REsStats)+
         geom_line(aes(Pos,C.T/C),color="red",data=data.frame(da))+
         geom_line(aes(Pos,G.A/G),color="green",data=data.frame(da))+
         geom_line(aes(Pos,((A.C+A.G+A.T)/A+(C.A+C.G)/C+(G.C+G.T)/G+(T.A+T.C+T.G)/T)/10),color="blue",data=data.frame(da))+
         ylab("Substitution rate")+
         xlab("Position")+
         labs(colour = "Subs. type")+
         ggtitle("Posterior prediction intervals")
         )
}


writeMCMC <- function(out,filename){
    #Writes the posterior samples to a file
    parameters <- c("Theta","DeltaD","DeltaS","Lambda")
    if (!out$cu_pa$same_overhangs){
        parameters <- c(parameters,"LambdaRight")
    }
    if (!out$cu_pa$fix_disp){
        parameters <- c(parameters,"LambdaDisp")
    }
    if (out$cu_pa$nuSamples!=0){
        parameters <- c(parameters,"Nu")
    }
    parameters <- c(parameters,"LogLik")
    write.csv(out$out[,parameters],paste(filename,".csv",sep=""))
    #Now calculate summary statistic of the posterior distributions
    mea <- apply(out$out[,parameters],2,mean)
    std <- apply(out$out[,parameters],2,sd)
    qua <- apply(out$out[,parameters],2,quantile,seq(from=0,to=1,by=.05))
    acc <- apply(out$out[,parameters],2,accRat)
    summStat <- rbind(mea,std,acc,qua)
    rownames(summStat)[1] <- "Mean" 
    rownames(summStat)[2] <- "Std." 
    rownames(summStat)[3] <- "Acceptance ratio" 
    write.csv(summStat,paste(filename,"_summ_stat.csv",sep=""))

}
